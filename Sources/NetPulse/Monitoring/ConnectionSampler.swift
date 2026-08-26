import Foundation

/// One process's currently-open remote connections, grouped by remote IP
/// (pre reverse-DNS) with a count of connections to each.
struct ConnectionInfo {
    let pid: Int32
    let command: String
    let remoteCounts: [String: Int]
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
    var onSample: (([ConnectionInfo]) -> Void)?
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
            case .success(let infos):
                DispatchQueue.main.async { self.onSample?(infos) }
            case .failure(let error):
                DispatchQueue.main.async { self.onStatusChange?(.degraded(error.message)) }
            }
        }
    }

    private static func runLsof() -> Result<[ConnectionInfo], SamplerError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // -F pcfn: lsof's machine-readable "field output" mode (documented,
        // stable for scripting — unlike the column-aligned default, which
        // truncates COMMAND and shifts with terminal width).
        //   p<pid>   starts a process record
        //   c<name>  command name for that process
        //   f<fd>    starts a file-descriptor record
        //   n<name>  that file's name — for a connected socket,
        //            "local->remote"
        p.arguments = ["lsof", "-i", "-n", "-P", "-F", "pcfn"]
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

    private static func parse(_ text: String) -> [ConnectionInfo] {
        var result: [ConnectionInfo] = []
        var pid: Int32?
        var command = ""
        var remoteCounts: [String: Int] = [:]

        func flush() {
            if let pid, !remoteCounts.isEmpty {
                result.append(ConnectionInfo(pid: pid, command: command, remoteCounts: remoteCounts))
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
            case "c":
                command = value
            case "n":
                if let remote = remoteHost(fromLsofName: value) {
                    remoteCounts[remote, default: 0] += 1
                }
            default:
                break
            }
        }
        flush()
        return result
    }

    /// lsof's `n` field for a connected socket looks like
    /// `192.168.1.5:53482->172.217.14.234:443` (or bracketed for IPv6).
    /// Listening sockets (`*:port`, no `->`) have no remote peer and are
    /// skipped.
    private static func remoteHost(fromLsofName name: String) -> String? {
        guard let arrowRange = name.range(of: "->") else { return nil }
        var remote = String(name[arrowRange.upperBound...])
        if let space = remote.firstIndex(of: " ") { remote = String(remote[..<space]) }
        if remote.hasPrefix("[") {
            guard let close = remote.firstIndex(of: "]") else { return nil }
            return String(remote[remote.index(after: remote.startIndex)..<close])
        }
        guard let colon = remote.lastIndex(of: ":") else { return remote }
        return String(remote[..<colon])
    }
}
