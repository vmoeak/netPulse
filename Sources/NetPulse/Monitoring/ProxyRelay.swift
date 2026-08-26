import Foundation
import Network

/// One flush interval's worth of relayed traffic for a (process, host) pair.
struct ProxyFlowDelta {
    let pid: Int32
    let host: String
    let downKB: Double
    let upKB: Double
    let newConnections: Int
}

/// A local HTTP proxy that sits in front of the user's real one.
///
/// Everything else in this app *estimates* which host an app's bytes went to,
/// because the kernel only reports per-process totals and, behind a local
/// proxy, every socket points at 127.0.0.1. Relaying the traffic is the one
/// way to know: the client announces its destination in cleartext
/// (`CONNECT host:443`, or an absolute-URI request line) before any TLS
/// handshake, and the bytes that follow can simply be counted as they pass.
///
/// Nothing is decrypted or modified — after the request head is read the two
/// sockets are pumped into each other verbatim, so TLS stays end-to-end
/// between the app and the site. What this does buy is exactness: the host,
/// the process behind it, and the byte counts are all measured rather than
/// inferred.
///
/// The cost is that NetPulse is in the data path: while the system proxy
/// points here, traffic stops if this stops. That is why it is opt-in and
/// why the app never switches the system proxy on its own.
final class ProxyRelay {
    struct Config {
        var listenPort: UInt16 = 1083
        var upstreamHost: String
        var upstreamPort: UInt16
    }

    var onFlowUpdate: (([ProxyFlowDelta]) -> Void)?
    var onStatusChange: ((MonitoringStatus) -> Void)?

    private struct Accumulator {
        let pid: Int32
        let host: String
        var downBytes: Int = 0
        var upBytes: Int = 0
        var newConnections: Int = 0
    }

    private let queue = DispatchQueue(label: "dev.vmoeak.netpulse.relay", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private var owners: SocketOwnerLookup?
    private var config: Config?
    private var pending: [String: Accumulator] = [:]
    private var flushTimer: Timer?

    private static let headTerminator = Data("\r\n\r\n".utf8)
    private static let maxHeadBytes = 64 * 1024
    private static let chunk = 64 * 1024

    /// Call from the main thread: the flush timer joins the current run loop.
    func start(config: Config) {
        stop()
        guard let port = NWEndpoint.Port(rawValue: config.listenPort) else {
            onStatusChange?(.unavailable("端口 \(config.listenPort) 无效"))
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: this relay has no business accepting from the network.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            onStatusChange?(.unavailable("无法监听 \(config.listenPort)：\(error.localizedDescription)"))
            return
        }

        self.config = config
        self.owners = SocketOwnerLookup(listenPort: config.listenPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.onStatusChange?(.ok)
                }
            case .failed(let error):
                DispatchQueue.main.async {
                    self.onStatusChange?(.unavailable("代理中继失败：\(error.localizedDescription)"))
                }
            default:
                break
            }
        }
        listener.start(queue: queue)

        flushTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.flush()
        }
    }

    func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        owners = nil
        config = nil
        lock.lock()
        pending = [:]
        lock.unlock()
    }

    // MARK: - Connection handling

    private func accept(_ client: NWConnection) {
        guard let config else { client.cancel(); return }
        client.start(queue: queue)
        readHead(from: client, buffer: Data()) { [weak self] head in
            guard let self, let head, let host = Self.host(fromHead: head.data) else {
                client.cancel()
                return
            }
            let pid = self.clientPID(for: client)
            self.connectUpstream(client: client, head: head.data, host: host, pid: pid, config: config)
        }
    }

    private struct Head {
        let data: Data
    }

    /// Reads until the end of the request head, keeping whatever body bytes
    /// arrived with it — they are forwarded verbatim along with the head.
    private func readHead(from connection: NWConnection,
                          buffer: Data,
                          completion: @escaping (Head?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Self.headTerminator) != nil {
                completion(Head(data: buffer))
                return
            }
            guard let self, error == nil, !isComplete, buffer.count <= Self.maxHeadBytes else {
                completion(nil)
                return
            }
            self.readHead(from: connection, buffer: buffer, completion: completion)
        }
    }

    private func connectUpstream(client: NWConnection,
                                 head: Data,
                                 host: String,
                                 pid: Int32,
                                 config: Config) {
        let upstream = NWConnection(host: NWEndpoint.Host(config.upstreamHost),
                                    port: NWEndpoint.Port(rawValue: config.upstreamPort) ?? 8080,
                                    using: .tcp)
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.record(pid: pid, host: host, up: head.count, down: 0, newConnection: 1)
                upstream.send(content: head, completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil else {
                        client.cancel()
                        upstream.cancel()
                        return
                    }
                    self.pump(from: client, to: upstream, isUpload: true, pid: pid, host: host)
                    self.pump(from: upstream, to: client, isUpload: false, pid: pid, host: host)
                })
            case .failed, .cancelled:
                client.cancel()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// Byte pump with backpressure: the next receive is only issued once the
    /// previous chunk has been handed to the other side, so a slow peer can't
    /// make this buffer without bound.
    private func pump(from source: NWConnection,
                      to destination: NWConnection,
                      isUpload: Bool,
                      pid: Int32,
                      host: String) {
        source.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, isComplete, error in
            guard let self else {
                source.cancel()
                destination.cancel()
                return
            }
            if let data, !data.isEmpty {
                self.record(pid: pid,
                            host: host,
                            up: isUpload ? data.count : 0,
                            down: isUpload ? 0 : data.count,
                            newConnection: 0)
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, sendError == nil, !isComplete else {
                        source.cancel()
                        destination.cancel()
                        return
                    }
                    self.pump(from: source, to: destination, isUpload: isUpload, pid: pid, host: host)
                })
                return
            }
            if isComplete || error != nil {
                source.cancel()
                destination.cancel()
                return
            }
            self.pump(from: source, to: destination, isUpload: isUpload, pid: pid, host: host)
        }
    }

    private func clientPID(for connection: NWConnection) -> Int32 {
        guard case let .hostPort(_, port) = connection.endpoint else { return -1 }
        return owners?.pid(forSourcePort: port.rawValue) ?? -1
    }

    // MARK: - Accounting

    private func record(pid: Int32, host: String, up: Int, down: Int, newConnection: Int) {
        let key = "\(pid)|\(host)"
        lock.lock()
        var accumulator = pending[key] ?? Accumulator(pid: pid, host: host)
        accumulator.upBytes += up
        accumulator.downBytes += down
        accumulator.newConnections += newConnection
        pending[key] = accumulator
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending = [:]
        lock.unlock()
        guard !batch.isEmpty else { return }
        onFlowUpdate?(batch.values.map {
            ProxyFlowDelta(pid: $0.pid,
                           host: $0.host,
                           downKB: Double($0.downBytes) / 1024,
                           upKB: Double($0.upBytes) / 1024,
                           newConnections: $0.newConnections)
        })
    }

    // MARK: - Request head

    /// The destination, from `CONNECT host:443 HTTP/1.1`, from an absolute
    /// URI (`GET http://host/path`), or failing both from the Host header.
    static func host(fromHead head: Data) -> String? {
        guard let text = String(data: head.prefix(maxHeadBytes), encoding: .utf8) ?? String(data: head.prefix(maxHeadBytes), encoding: .isoLatin1) else {
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if parts.count >= 2 {
            let target = String(parts[1])
            if parts[0] == "CONNECT" {
                return stripPort(target)
            }
            if let url = URL(string: target), let host = url.host {
                return host
            }
        }
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let lower = line.lowercased()
            guard lower.hasPrefix("host:") else { continue }
            let value = line.dropFirst("host:".count).trimmingCharacters(in: .whitespaces)
            return stripPort(value)
        }
        return nil
    }

    private static func stripPort(_ authority: String) -> String? {
        guard !authority.isEmpty else { return nil }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            return String(authority[authority.index(after: authority.startIndex)..<close])
        }
        guard let colon = authority.lastIndex(of: ":") else { return authority }
        return String(authority[..<colon])
    }
}
