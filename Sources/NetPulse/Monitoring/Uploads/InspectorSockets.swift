import Foundation
import Darwin
import Security

/// A non-blocking socket with bytes pushed back in front of it — what the
/// proxy read past a request head before it knew who would consume them.
final class SocketIO {
    let fd: Int32
    var pushback: [UInt8] = []
    private var closed = false
    private let lock = NSLock()

    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Up to `max` bytes without waiting: nil once closed, empty when
    /// nothing has arrived yet.
    func readSome(max: Int) -> [UInt8]? {
        if !pushback.isEmpty {
            let n = min(max, pushback.count)
            let out = Array(pushback.prefix(n))
            pushback.removeFirst(n)
            return out
        }
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let n = Darwin.read(fd, &buffer, max)
            if n > 0 { return Array(buffer[0..<n]) }
            if n == 0 { return nil }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return [] }
            return nil
        }
    }

    /// Some bytes, waiting up to `timeout` ms for them; nil on close or timeout.
    func readWaiting(timeout: Int32) -> [UInt8]? {
        while true {
            guard let bytes = readSome(max: 64 * 1024) else { return nil }
            if !bytes.isEmpty { return bytes }
            guard wait(for: Int16(POLLIN), timeout: timeout) else { return nil }
        }
    }

    func writeAll(_ pointer: UnsafeRawPointer, count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = Darwin.write(fd, pointer.advanced(by: done), count - done)
            if n > 0 { done += n; continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                guard wait(for: Int16(POLLOUT), timeout: 60_000) else { return false }
                continue
            }
            return false
        }
        return true
    }

    func writeAll(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        return bytes.withUnsafeBytes { writeAll($0.baseAddress!, count: $0.count) }
    }

    func wait(for events: Int16, timeout: Int32) -> Bool {
        var p = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let r = poll(&p, 1, timeout)
            if r < 0, errno == EINTR { continue }
            return r > 0
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    /// Opens a TCP connection, trying each address the name resolves to.
    static func connect(host: String, port: Int, timeout: Int32 = 15_000) -> SocketIO? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            cursor = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            let io = SocketIO(fd: fd)
            if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return io }
            if errno == EINPROGRESS, io.wait(for: Int16(POLLOUT), timeout: timeout) {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                if error == 0 { return io }
            }
            io.close()
        }
        return nil
    }
}

/// One side of a relayed connection, plain or TLS.
protocol ByteStream: AnyObject {
    var io: SocketIO { get }
    /// Bytes ready without waiting: nil once the peer is gone, empty when
    /// nothing is ready.
    func readAvailable() -> [UInt8]?
    /// Bytes already received but not handed out, which poll() can't see.
    var hasBuffered: Bool { get }
    func write(_ bytes: [UInt8]) -> Bool
    func close()
}

final class PlainStream: ByteStream {
    let io: SocketIO
    init(io: SocketIO) { self.io = io }
    func readAvailable() -> [UInt8]? { io.readSome(max: 64 * 1024) }
    var hasBuffered: Bool { !io.pushback.isEmpty }
    func write(_ bytes: [UInt8]) -> Bool { io.writeAll(bytes) }
    func close() { io.close() }
}

// SecureTransport is deprecated, but it is the one TLS stack on macOS that
// runs over a socket the caller already holds (after a proxy CONNECT, on
// either side), with nothing to install. It speaks TLS 1.2, which every
// client and API server still accepts.

private func tlsRead(_ connection: SSLConnectionRef, _ data: UnsafeMutableRawPointer,
                     _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let io = Unmanaged<SocketIO>.fromOpaque(connection).takeUnretainedValue()
    let wanted = length.pointee
    var done = 0
    while done < wanted {
        guard let chunk = io.readSome(max: wanted - done) else {
            length.pointee = done
            return errSSLClosedGraceful
        }
        if chunk.isEmpty {
            length.pointee = done
            return errSSLWouldBlock
        }
        chunk.withUnsafeBytes { data.advanced(by: done).copyMemory(from: $0.baseAddress!, byteCount: chunk.count) }
        done += chunk.count
    }
    length.pointee = done
    return noErr
}

private func tlsWrite(_ connection: SSLConnectionRef, _ data: UnsafeRawPointer,
                      _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let io = Unmanaged<SocketIO>.fromOpaque(connection).takeUnretainedValue()
    if io.writeAll(data, count: length.pointee) { return noErr }
    length.pointee = 0
    return errSSLClosedAbort
}

final class TLSStream: ByteStream {
    let io: SocketIO
    private let context: SSLContext

    private init?(io: SocketIO, side: SSLProtocolSide) {
        guard let context = SSLCreateContext(nil, side, .streamType) else { return nil }
        self.io = io
        self.context = context
        SSLSetIOFuncs(context, tlsRead, tlsWrite)
        SSLSetConnection(context, UnsafeRawPointer(Unmanaged.passUnretained(io).toOpaque()))
        SSLSetProtocolVersionMin(context, .tlsProtocol12)
    }

    /// Our end of the app's TLS, presenting a certificate for the host it
    /// asked for.
    static func server(io: SocketIO, identity: SecIdentity) -> TLSStream? {
        guard let stream = TLSStream(io: io, side: .serverSide) else { return nil }
        guard SSLSetCertificate(stream.context, [identity] as CFArray) == noErr else { return nil }
        return stream
    }

    /// TLS to the real server, verifying its certificate against the
    /// system's trust store as any client would.
    static func client(io: SocketIO, host: String) -> TLSStream? {
        guard let stream = TLSStream(io: io, side: .clientSide) else { return nil }
        guard SSLSetPeerDomainName(stream.context, host, host.utf8.count) == noErr else { return nil }
        return stream
    }

    func handshake(timeout: Int32 = 20_000) -> OSStatus {
        while true {
            let status = SSLHandshake(context)
            guard status == errSSLWouldBlock else { return status }
            guard io.wait(for: Int16(POLLIN), timeout: timeout) else { return errSSLClosedAbort }
        }
    }

    func readAvailable() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        var processed = 0
        let status = SSLRead(context, &buffer, buffer.count, &processed)
        if processed > 0 { return Array(buffer[0..<processed]) }
        if status == errSSLWouldBlock || status == noErr { return [] }
        return nil
    }

    var hasBuffered: Bool {
        var size = 0
        SSLGetBufferedReadSize(context, &size)
        return size > 0 || !io.pushback.isEmpty
    }

    func write(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        var offset = 0
        while offset < bytes.count {
            var processed = 0
            let status = bytes.withUnsafeBytes {
                SSLWrite(context, $0.baseAddress!.advanced(by: offset), bytes.count - offset, &processed)
            }
            offset += processed
            if status != noErr && status != errSSLWouldBlock { return false }
            if status == errSSLWouldBlock && processed == 0 {
                guard io.wait(for: Int16(POLLOUT), timeout: 60_000) else { return false }
            }
        }
        return true
    }

    func close() {
        SSLClose(context)
        io.close()
    }
}

enum Relay {
    /// Copies bytes both ways until either side closes or the connection
    /// sits idle for `idleTimeout` ms, handing what the client sends to
    /// `tap` before it goes on to the server.
    static func run(client: ByteStream, server: ByteStream, idleTimeout: Int32 = 10 * 60_000,
                    tap: ([UInt8]) -> Void) {
        var fds = [pollfd(fd: client.io.fd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: server.io.fd, events: Int16(POLLIN), revents: 0)]
        while true {
            fds[0].revents = 0
            fds[1].revents = 0
            if !client.hasBuffered && !server.hasBuffered {
                let r = poll(&fds, 2, idleTimeout)
                if r < 0 && errno == EINTR { continue }
                if r <= 0 { return }
            }
            if client.hasBuffered || fds[0].revents != 0 {
                guard pump(from: client, to: server, tap: tap) else { return }
            }
            if server.hasBuffered || fds[1].revents != 0 {
                guard pump(from: server, to: client, tap: { _ in }) else { return }
            }
        }
    }

    private static func pump(from source: ByteStream, to sink: ByteStream, tap: ([UInt8]) -> Void) -> Bool {
        while true {
            guard let bytes = source.readAvailable() else { return false }
            if bytes.isEmpty { return true }
            tap(bytes)
            guard sink.write(bytes) else { return false }
        }
    }
}
