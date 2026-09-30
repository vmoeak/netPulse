import Foundation
import Darwin

/// Names the site behind each connection an app makes to a local proxy
/// (Shadowrocket's system proxy on 127.0.0.1:1082, Clash, …).
///
/// Through a system proxy an app connects to localhost and its first bytes
/// say where to: `CONNECT github.com:443 HTTP/1.1`, or a SOCKS5 request with
/// the domain. That line is plaintext on the loopback interface; everything
/// after it is the site's own (encrypted) traffic. Capturing it needs root,
/// so it is done by a launchd daemon the user installs once with an
/// administrator password, which runs `tcpdump` on lo0 with a filter that
/// only passes packets *starting* with such a request, and writes them into
/// a FIFO only this user can read. Nothing is written to disk: the FIFO holds
/// no data, and while NetPulse isn't reading, the daemon waits to open it
/// and captures nothing.
///
/// What NetPulse keeps is the client's source port → site, in memory; the
/// per-connection nettop counters for that port then give the site's bytes.
final class ProxyHostCapture {
    static let label = "local.netpulse.proxy-host-capture"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    /// Called on the main queue with newly seen source port → host pairs.
    var onHosts: (([Int: String]) -> Void)?

    private let fifoURL: URL
    private var reader: Thread?
    private var stopped = true

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetPulse", isDirectory: true)) {
        fifoURL = directory.appendingPathComponent("proxy-hosts.fifo")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    func start() {
        guard Self.isInstalled, reader == nil, (try? makeFIFO()) != nil else { return }
        stopped = false
        let path = fifoURL.path
        let thread = Thread { [weak self] in self?.readLoop(path: path) }
        thread.name = "NetPulse.proxyHostCapture"
        thread.qualityOfService = .utility
        reader = thread
        thread.start()
    }

    func stop() {
        stopped = true
        reader = nil
    }

    /// Creates the FIFO the daemon writes into: owned by this user, mode 600,
    /// so other accounts on the Mac can't read what sites were visited.
    private func makeFIFO() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fifoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var info = stat()
        if lstat(fifoURL.path, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFIFO, info.st_uid == getuid() {
                chmod(fifoURL.path, 0o600)
                return
            }
            try fm.removeItem(at: fifoURL)
        }
        guard mkfifo(fifoURL.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func readLoop(path: String) {
        var parser = TcpdumpConnectParser()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var pending = Data()
        while !stopped {
            // Blocks until the daemon opens its end.
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { Thread.sleep(forTimeInterval: 5); continue }
            while !stopped {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                var found: [Int: String] = [:]
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if let hit = parser.feed(line: line) { found[hit.sourcePort] = hit.host }
                }
                if !found.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.onHosts?(found) }
                }
            }
            close(fd)
            pending.removeAll()
        }
    }

    // MARK: - Installing the daemon

    /// Only packets whose TCP payload starts with "CONN" (an HTTP CONNECT) or
    /// 05 01 00 03 (a SOCKS5 CONNECT to a domain), over IPv4 or IPv6.
    static let filter = [
        "(ip and (tcp[((tcp[12]&0xf0)>>2):4] = 0x434f4e4e or tcp[((tcp[12]&0xf0)>>2):4] = 0x05010003))",
        "(ip6 and ip6[6] = 6 and (ip6[40+((ip6[52]&0xf0)>>2):4] = 0x434f4e4e",
        "or ip6[40+((ip6[52]&0xf0)>>2):4] = 0x05010003))",
    ].joined(separator: " or ")

    func daemonPlist() -> Data {
        let plist: [String: Any] = [
            "Label": Self.label,
            // $0 is the filter and $1 the FIFO, so neither needs quoting.
            // The redirect blocks until NetPulse opens the FIFO; when it
            // closes it, tcpdump dies of SIGPIPE and launchd starts it again.
            "ProgramArguments": ["/bin/sh", "-c",
                                 "exec /usr/sbin/tcpdump -i lo0 -n -l -x -s 400 \"$0\" > \"$1\" 2>/dev/null",
                                 Self.filter, fifoURL.path],
            "KeepAlive": true,
            "RunAtLoad": true,
            "ThrottleInterval": 5,
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    /// Installs and starts the daemon, asking for an administrator password.
    /// The plist goes in as base64 inside the privileged command itself, so
    /// there is no user-writable file for root to pick up.
    func install() -> String? {
        do { try makeFIFO() } catch { return "无法创建管道：\(error.localizedDescription)" }
        let b64 = daemonPlist().base64EncodedString()
        let command = [
            "echo \(b64) | /usr/bin/base64 -D > \(Self.plistPath)",
            "/usr/sbin/chown root:wheel \(Self.plistPath)",
            "/bin/chmod 644 \(Self.plistPath)",
            "/bin/launchctl bootout system/\(Self.label) 2>/dev/null; /bin/launchctl bootstrap system \(Self.plistPath)",
        ].joined(separator: " && ")
        if let error = Self.runAsAdmin(command, prompt: "NetPulse 要安装一个只读取本机代理连接目标网站的抓包服务。") { return error }
        start()
        return nil
    }

    func uninstall() -> String? {
        stop()
        let command = "/bin/launchctl bootout system/\(Self.label) 2>/dev/null; /bin/rm -f \(Self.plistPath)"
        return Self.runAsAdmin(command, prompt: "NetPulse 要移除代理网站统计服务。")
    }

    private static func runAsAdmin(_ command: String, prompt: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        // -128: the user cancelled the password prompt.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "已取消" }
        return error[NSAppleScript.errorMessage] as? String ?? "安装失败"
    }
}

/// Reads `tcpdump -x` output: a header line per packet, then hex lines of
/// the packet from its IP header on. Yields the TCP source port and the
/// host named by the CONNECT or SOCKS5 request the packet starts with.
struct TcpdumpConnectParser {
    private var bytes: [UInt8] = []
    private var done = true

    mutating func feed(line: String) -> (sourcePort: Int, host: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("0x") else {
            // A new packet's header line.
            bytes = []
            done = trimmed.isEmpty
            return nil
        }
        guard !done else { return nil }
        // "0x0010:  7f00 0001 ddfa 043a ..." — the offset, then hex groups.
        for group in trimmed.split(separator: " ").dropFirst() {
            var chars = Substring(group)
            while chars.count >= 2 {
                guard let byte = UInt8(chars.prefix(2), radix: 16) else { break }
                bytes.append(byte)
                chars = chars.dropFirst(2)
            }
        }
        guard let hit = Self.parse(packet: bytes) else { return nil }
        done = true
        return hit
    }

    static func parse(packet: [UInt8]) -> (sourcePort: Int, host: String)? {
        guard let version = packet.first.map({ $0 >> 4 }) else { return nil }
        let ipHeader: Int
        switch version {
        case 4: ipHeader = Int(packet[0] & 0x0f) * 4
        case 6: ipHeader = 40
        default: return nil
        }
        guard packet.count >= ipHeader + 20 else { return nil }
        let sourcePort = Int(packet[ipHeader]) << 8 | Int(packet[ipHeader + 1])
        let payloadStart = ipHeader + Int(packet[ipHeader + 12] >> 4) * 4
        guard packet.count > payloadStart else { return nil }
        let payload = Array(packet[payloadStart...])
        guard let host = host(inRequest: payload) else { return nil }
        return (sourcePort, host)
    }

    static func host(inRequest payload: [UInt8]) -> String? {
        if payload.starts(with: Array("CONNECT ".utf8)) {
            let rest = payload.dropFirst(8)
            guard let end = rest.firstIndex(where: { $0 == 0x20 || $0 == 0x0D }) else { return nil }
            let target = String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
            // host:port, or [v6]:port.
            if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
                return String(target[target.index(after: target.startIndex)..<close])
            }
            guard let colon = target.lastIndex(of: ":") else { return clean(target) }
            return clean(String(target[..<colon]))
        }
        if payload.count > 5, payload[0] == 0x05, payload[1] == 0x01, payload[3] == 0x03 {
            let length = Int(payload[4])
            guard payload.count >= 5 + length else { return nil }
            return clean(String(decoding: payload[5..<(5 + length)], as: UTF8.self))
        }
        return nil
    }

    private static func clean(_ host: String) -> String? {
        let host = host.lowercased()
        guard !host.isEmpty, host.count <= 253,
              host.allSatisfy({ $0.isLetter || $0.isNumber || "-.:_".contains($0) }) else { return nil }
        return host
    }
}
