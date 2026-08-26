import Foundation

/// One process's currently-open remote connections, grouped by remote IP
/// (pre reverse-DNS) with a count of connections to each.
struct ConnectionInfo {
    let pid: Int32
    let command: String
    let remoteCounts: [String: Int]
    /// Loopback connections, keyed by the remote *port* rather than by
    /// address. On a Mac running a local proxy this is where most of a
    /// browser's sockets live, and 127.0.0.1 alone says nothing — the port
    /// is what identifies which local process is on the other end.
    let loopbackCounts: [Int: Int]
}

/// The process holding a listening port, so a loopback peer can be named.
struct ListenerInfo {
    let pid: Int32
    let command: String
}

/// One `lsof` pass: what everyone is connected to, plus who is listening
/// where, which is what turns "localhost" into a name.
struct ConnectionSnapshot {
    let connections: [ConnectionInfo]
    let listeners: [Int: ListenerInfo]
}

/// `Result`'s failure type has to conform to `Error`, so the human-readable
/// message this sampler surfaces to the UI is wrapped instead of being passed
/// around as a bare `String`.
struct SamplerError: Error {
    let message: String
}

/// Polls `lsof -i` periodically to discover which remote hosts each process
/// is talking to right now. This has no byte-count information — only
/// connection presence/count — so it's paired with `NettopSampler`'s
/// per-app rate to *estimate* a per-domain split (see
/// `NetworkMonitorEngine`). Lighter weight than nettop's connection-level
/// mode, so it runs on its own slower interval.
final class ConnectionSampler {
    var onSample: ((ConnectionSnapshot) -> Void)?
    var onStatusChange: ((MonitoringStatus) -> Void)?

    private let interval: TimeInterval
    private var timer: Timer?

    init(interval: TimeInterval = 3) {
        self.interval = interval
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            switch Self.runLsof() {
            case .success(let snapshot):
                DispatchQueue.main.async { self.onSample?(snapshot) }
            case .failure(let error):
                DispatchQueue.main.async { self.onStatusChange?(.degraded(error.message)) }
            }
        }
    }

    private static func runLsof() -> Result<ConnectionSnapshot, SamplerError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // -F pcfnP: lsof's machine-readable "field output" mode (documented,
        // stable for scripting — unlike the column-aligned default, which
        // truncates COMMAND and shifts with terminal width).
        //   p<pid>   starts a process record
        //   c<name>  command name for that process
        //   f<fd>    starts a file-descriptor record
        //   P<proto> TCP or UDP, used to keep UDP sockets from being mistaken
        //            for listeners
        //   n<name>  that file's name — for a connected socket,
        //            "local->remote"; for a listening one just "*:port"
        // +c 0 stops lsof truncating the command name to 9 characters, which
        // matters because that name is what a loopback peer gets labelled with.
        p.arguments = ["lsof", "-i", "-n", "-P", "+c", "0", "-F", "pcfnP"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return .failure(SamplerError(message: "无法启动 lsof：\(error.localizedDescription)"))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(SamplerError(message: "lsof 输出无法解码"))
        }
        return .success(parse(text))
    }

    private static func parse(_ text: String) -> ConnectionSnapshot {
        var result: [ConnectionInfo] = []
        var listeners: [Int: ListenerInfo] = [:]
        var pid: Int32?
        var command = ""
        var remoteCounts: [String: Int] = [:]
        var loopbackCounts: [Int: Int] = [:]
        var proto = ""

        func flush() {
            if let pid, !(remoteCounts.isEmpty && loopbackCounts.isEmpty) {
                result.append(ConnectionInfo(pid: pid,
                                            command: command,
                                            remoteCounts: remoteCounts,
                                            loopbackCounts: loopbackCounts))
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flush()
                pid = Int32(value)
                command = ""
                remoteCounts = [:]
                loopbackCounts = [:]
            case "c":
                command = value
            case "f":
                proto = ""
            case "P":
                proto = value
            case "n":
                if let peer = remotePeer(fromLsofName: value) {
                    if isLoopback(peer.host), let port = peer.port {
                        loopbackCounts[port, default: 0] += 1
                    } else {
                        remoteCounts[peer.host, default: 0] += 1
                    }
                } else if proto == "TCP", let pid, let port = listeningPort(fromLsofName: value) {
                    // First one wins: a port can be held by several sockets
                    // (v4 and v6), and they are the same process anyway.
                    if listeners[port] == nil {
                        listeners[port] = ListenerInfo(pid: pid, command: command)
                    }
                }
            default:
                break
            }
        }
        flush()
        return ConnectionSnapshot(connections: result, listeners: listeners)
    }

    /// lsof's `n` field for a connected socket looks like
    /// `192.168.1.5:53482->172.217.14.234:443` (or bracketed for IPv6).
    /// Listening sockets (`*:port`, no `->`) have no remote peer.
    private static func remotePeer(fromLsofName name: String) -> (host: String, port: Int?)? {
        guard let arrowRange = name.range(of: "->") else { return nil }
        var remote = String(name[arrowRange.upperBound...])
        if let space = remote.firstIndex(of: " ") { remote = String(remote[..<space]) }
        return splitHostPort(remote)
    }

    private static func listeningPort(fromLsofName name: String) -> Int? {
        var local = name
        if let space = local.firstIndex(of: " ") { local = String(local[..<space]) }
        guard !local.contains("->") else { return nil }
        return splitHostPort(local)?.port
    }

    private static func splitHostPort(_ endpoint: String) -> (host: String, port: Int?)? {
        if endpoint.hasPrefix("[") {
            guard let close = endpoint.firstIndex(of: "]") else { return nil }
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            let rest = endpoint[endpoint.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        guard let colon = endpoint.lastIndex(of: ":") else { return (endpoint, nil) }
        return (String(endpoint[..<colon]), Int(endpoint[endpoint.index(after: colon)...]))
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.")
    }
}
