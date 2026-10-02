import Foundation
import Darwin
import Security

/// What one relayed connection told the inspector: a request the app sent,
/// or a TLS handshake the app refused (it doesn't trust the CA, or pins its
/// server's certificate).
struct InspectorEvent {
    var date = Date()
    var host: String
    var port: Int
    var scheme: String
    var pid: Int32?
    var processName: String
    /// `ProcessDirectory` identity of the client, the id `AppUsage` rows use.
    var appID: String? = nil
    var request: ParsedRequest?
    var failure: String?
}

/// An HTTP proxy on 127.0.0.1 that shows what apps send through it.
///
/// An app pointed at it (`HTTPS_PROXY=http://127.0.0.1:<port>`) asks for
/// each site with `CONNECT`; the proxy answers the app's TLS with a
/// certificate for that site signed by `InspectorCA`, opens its own TLS to
/// the real site (through the system proxy when one is set, e.g.
/// Shadowrocket), and relays the bytes. On the way it reads the app's side
/// as HTTP requests and reports each one. The server's replies are passed
/// through untouched and unread. Only apps told to use the proxy (and to
/// trust the CA) are seen; everything else on the Mac is unaffected.
final class InspectorProxy {
    var onEvent: ((InspectorEvent) -> Void)?

    private let ca: InspectorCA
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private(set) var port: UInt16 = 0

    init(ca: InspectorCA) {
        self.ca = ca
    }

    /// Listens on the first free port from `preferred` on; returns it.
    func start(preferred: UInt16, attempts: UInt16 = 10) throws -> UInt16 {
        signal(SIGPIPE, SIG_IGN)
        var lastError = ""
        for candidate in preferred..<(preferred + attempts) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw InspectorCA.Failure(message: "无法创建监听端口") }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = candidate.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 128) == 0 else {
                lastError = String(cString: strerror(errno))
                Darwin.close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            lock.lock()
            listenFD = fd
            running = true
            port = candidate
            lock.unlock()
            let thread = Thread { [weak self] in self?.acceptLoop(fd: fd) }
            thread.name = "NetPulse.inspector.accept"
            thread.start()
            return candidate
        }
        throw InspectorCA.Failure(message: "端口 \(preferred)–\(preferred + attempts - 1) 都无法监听：\(lastError)")
    }

    func stop() {
        lock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop(fd: Int32) {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while isRunning {
            // A timeout rather than blocking in accept(), so stop() is seen.
            p.revents = 0
            guard poll(&p, 1, 500) > 0 else { continue }
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            guard client >= 0 else { continue }
            let peerPort = Int(UInt16(bigEndian: peer.sin_port))
            let thread = Thread { [weak self] in
                guard let self else { Darwin.close(client); return }
                self.handle(io: SocketIO(fd: client), peerPort: peerPort)
            }
            thread.name = "NetPulse.inspector.connection"
            thread.start()
        }
    }

    // MARK: - One connection

    private func handle(io: SocketIO, peerPort: Int) {
        defer { io.close() }
        guard let read = Self.readHead(io) else { return }
        let head = read.head, rest = read.rest
        guard let request = HTTPRequestParser.parseHead(head[...]) else {
            _ = io.writeAll(Array("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
            return
        }
        let client = Self.clientProcess(peerPort: peerPort)
        if request.method == "CONNECT" {
            guard let target = Self.splitHostPort(request.target, defaultPort: 443) else { return }
            let host = target.host, port = target.port
            io.pushback = rest
            guard io.writeAll(Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)),
                  let first = io.readWaiting(timeout: 30_000) else { return }
            io.pushback = first + io.pushback
            if first.first == 0x16 {
                intercept(client: io, host: host, port: port, process: client)
            } else {
                // Not TLS (plain HTTP or a WebSocket through CONNECT).
                guard let upstream = openTunnel(host: host, port: port) else { return }
                defer { upstream.close() }
                relay(client: PlainStream(io: io), server: PlainStream(io: upstream),
                      host: host, port: port, scheme: "http", process: client)
            }
        } else {
            // A plain-HTTP proxy request, "GET http://host/path HTTP/1.1".
            // Servers must accept the absolute form too, so it goes on as is.
            guard let url = URL(string: request.target), url.scheme?.lowercased() == "http", let host = url.host else {
                _ = io.writeAll(Array("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
                return
            }
            let port = url.port ?? 80
            let upstream: SocketIO?
            if let proxy = Self.systemProxy(https: false, excludingPort: self.port) {
                upstream = SocketIO.connect(host: proxy.host, port: proxy.port)
            } else {
                upstream = SocketIO.connect(host: host, port: port)
            }
            guard let upstream else {
                _ = io.writeAll(Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
                return
            }
            defer { upstream.close() }
            io.pushback = head + rest
            relay(client: PlainStream(io: io), server: PlainStream(io: upstream),
                  host: host, port: port, scheme: "http", process: client)
        }
    }

    private func intercept(client io: SocketIO, host: String, port: Int, process: (pid: Int32, name: String, appID: String)?) {
        let identity: SecIdentity
        do {
            identity = try ca.identity(for: host)
        } catch {
            report(host: host, port: port, scheme: "https", process: process, failure: error.localizedDescription)
            return
        }
        guard let clientTLS = TLSStream.server(io: io, identity: identity) else { return }
        let status = clientTLS.handshake()
        guard status == noErr else {
            // The app saw our certificate and hung up: it doesn't trust the
            // CA, or it pins the site's own certificate.
            report(host: host, port: port, scheme: "https", process: process,
                   failure: "App 拒绝了 NetPulse 的证书（\(Self.describe(status))），没有信任 CA 或固定了证书")
            return
        }
        defer { clientTLS.close() }
        guard let upstream = openTunnel(host: host, port: port) else {
            report(host: host, port: port, scheme: "https", process: process, failure: "无法连接 \(host):\(port)")
            return
        }
        guard let serverTLS = TLSStream.client(io: upstream, host: host) else { upstream.close(); return }
        defer { serverTLS.close() }
        let serverStatus = serverTLS.handshake()
        guard serverStatus == noErr else {
            report(host: host, port: port, scheme: "https", process: process,
                   failure: "与 \(host) 的 TLS 握手失败（\(Self.describe(serverStatus))）")
            return
        }
        relay(client: clientTLS, server: serverTLS, host: host, port: port, scheme: "https", process: process)
    }

    private func relay(client: ByteStream, server: ByteStream, host: String, port: Int, scheme: String,
                       process: (pid: Int32, name: String, appID: String)?) {
        var parser = HTTPRequestParser()
        Relay.run(client: client, server: server) { bytes in
            guard !parser.isStopped else { return }
            for request in parser.feed(bytes) {
                onEvent?(InspectorEvent(host: host, port: port, scheme: scheme, pid: process?.pid,
                                        processName: process?.name ?? "未知进程", appID: process?.appID, request: request))
            }
        }
    }

    private func report(host: String, port: Int, scheme: String, process: (pid: Int32, name: String, appID: String)?, failure: String) {
        onEvent?(InspectorEvent(host: host, port: port, scheme: scheme, pid: process?.pid,
                                processName: process?.name ?? "未知进程", appID: process?.appID, failure: failure))
    }

    /// A TCP stream to `host:port`: through the system's HTTPS proxy when
    /// one is set (so sites only reachable through it still work), else
    /// direct.
    private func openTunnel(host: String, port: Int) -> SocketIO? {
        guard let proxy = Self.systemProxy(https: true, excludingPort: self.port) else {
            return SocketIO.connect(host: host, port: port)
        }
        guard let io = SocketIO.connect(host: proxy.host, port: proxy.port) else { return nil }
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        guard io.writeAll(Array("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n".utf8)),
              let reply = Self.readHead(io) else { io.close(); return nil }
        let status = String(decoding: reply.head.prefix(32), as: UTF8.self).split(separator: " ")
        guard status.count >= 2, status[1] == "200" else { io.close(); return nil }
        io.pushback = reply.rest
        return io
    }

    // MARK: - Helpers

    /// Reads up to the blank line ending a request head; returns the head
    /// (with its CRLFCRLF) and whatever came after it.
    static func readHead(_ io: SocketIO) -> (head: [UInt8], rest: [UInt8])? {
        var data: [UInt8] = []
        while true {
            if let end = indexOfBlankLine(in: data) {
                return (Array(data[..<(end + 4)]), Array(data[(end + 4)...]))
            }
            guard data.count < HTTPRequestParser.maxHead,
                  let chunk = io.readWaiting(timeout: 30_000) else { return nil }
            data += chunk
        }
    }

    private static func indexOfBlankLine(in data: [UInt8]) -> Int? {
        guard data.count >= 4 else { return nil }
        for i in 0...(data.count - 4) where data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10 {
            return i
        }
        return nil
    }

    /// "example.com:443", "[::1]:8443" → host and port.
    static func splitHostPort(_ target: String, defaultPort: Int) -> (host: String, port: Int)? {
        var host = target
        var port = defaultPort
        if target.hasPrefix("[") {
            guard let close = target.firstIndex(of: "]") else { return nil }
            host = String(target[target.index(after: target.startIndex)..<close])
            let after = target[target.index(after: close)...]
            if after.hasPrefix(":"), let p = Int(after.dropFirst()) { port = p }
        } else if let colon = target.lastIndex(of: ":") {
            host = String(target[..<colon])
            guard let p = Int(target[target.index(after: colon)...]) else { return nil }
            port = p
        }
        let allowed = host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._:".contains($0)) }
        guard !host.isEmpty, host.count <= 253, allowed, (1...65535).contains(port) else { return nil }
        return (host.lowercased(), port)
    }

    /// The system's HTTP(S) proxy, unless it is this inspector itself.
    static func systemProxy(https: Bool, excludingPort ownPort: UInt16) -> (host: String, port: Int)? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        let prefix = https ? "HTTPS" : "HTTP"
        guard (settings[prefix + "Enable"] as? Int) == 1,
              let host = settings[prefix + "Proxy"] as? String, !host.isEmpty,
              let port = settings[prefix + "Port"] as? Int else { return nil }
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
        if loopback && port == Int(ownPort) { return nil }
        return (host, port)
    }

    /// The process on the other end of a loopback connection from
    /// `peerPort`, by asking lsof who holds that port (other than us).
    static func clientProcess(peerPort: Int) -> (pid: Int32, name: String, appID: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP@127.0.0.1:\(peerPort)", "-sTCP:ESTABLISHED", "-Fp"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let me = getpid()
        let pids = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .compactMap { $0.hasPrefix("p") ? Int32($0.dropFirst()) : nil }
            .filter { $0 != me }
        guard let pid = pids.first else { return nil }
        let identity = ProcessDirectory.identify(pid: pid, fallbackCommand: "pid-\(pid)")
        return (pid, identity.name, identity.id)
    }

    private static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? { return "\(message) \(status)" }
        return "错误 \(status)"
    }
}
