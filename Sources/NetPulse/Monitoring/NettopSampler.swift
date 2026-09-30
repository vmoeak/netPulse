import Foundation

/// Samples per-process network byte counters from the built-in `nettop`
/// tool (no special entitlement needed, unlike the Network Extension APIs
/// that would give the mockup's precision).
///
/// ROW FORMAT: `nettop -x` writes whitespace-aligned columns, not CSV —
///
///     mDNSResponder.595                       9087000          372112
///
/// with the process name truncated to 15 characters (which only affects
/// daemons; GUI apps are renamed from their pid via `ProcessDirectory`).
/// `parseRow(_:)` scans a row's cells for the `"ProcessName.PID"` one
/// rather than assuming a position, and reads the last two numeric cells as
/// cumulative bytes-in/bytes-out. `-x` keeps those unabbreviated, so there
/// are no K/M suffixes to interpret.
///
/// When nothing parses for several runs, the status message says which
/// failure it was — nettop couldn't run (its stderr), produced no output, or
/// produced output no row of which was recognizable (quoted, so the real
/// format can be read off the UI).
///
/// `readConnections()` is the per-connection counterpart: one sample in
/// which each process row is followed by its connections (see `parseLine`),
/// whose counters split an app's bytes exactly by remote host.
/// What the engine needs from a per-process byte counter source — the real
/// `NettopSampler`, or canned samples in tests.
protocol NettopSource: AnyObject {
    var onStatusChange: ((MonitoringStatus) -> Void)? { get set }
    func start()
    func stop()
    func snapshot() -> [Int32: NettopSampler.Sample]
    func forget(pids: Set<Int32>)
}

final class NettopSampler: NettopSource {
    struct Sample {
        let pid: Int32
        let command: String
        /// Cumulative bytes received/sent since the process started, in KB.
        let bytesInCumKB: Double
        let bytesOutCumKB: Double
        /// The process's open connections, keyed by `"proto local<->remote"`
        /// (unique while the connection lives). Empty from sources that only
        /// report per-process totals.
        var connections: [String: Connection] = [:]
    }

    /// One connection's cumulative counters, in bytes.
    struct Connection: Equatable {
        /// Remote address as nettop printed it (`-n`, so never a name), or
        /// "*" for an unconnected socket.
        let remoteHost: String
        let remotePort: Int?
        let bytesIn: Double
        let bytesOut: Double
        /// This end's port: for an app talking to a local proxy, what names
        /// the connection in `ProxyHostCapture`.
        var localPort: Int? = nil

        var isLoopback: Bool {
            remoteHost == "::1" || remoteHost == "localhost" || remoteHost.hasPrefix("127.")
                || remoteHost.hasPrefix("::ffff:127.")
        }
    }

    var onStatusChange: ((MonitoringStatus) -> Void)?

    // A long-running nettop (-l 0) spins at over 100% CPU between samples on
    // macOS 26, whatever its options, while a one-shot run takes ~0.02 s.
    // So nettop is started once a second and exits after one sample; the
    // counters are cumulative, so nothing is lost between runs.
    private let queue = DispatchQueue(label: "NetPulse.nettop", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var latest: [Int32: Sample] = [:]
    /// Consecutive runs that produced no row, so
    /// a nettop that can't run says why instead of the list staying empty.
    private var failedRuns = 0
    private var reportedFailure = false

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        // Runs on the serial queue, so a slow run delays the next one
        // instead of overlapping it.
        t.setEventHandler { [weak self] in self?.sampleOnce() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Drops dead pids so their last counters stop being reported forever —
    /// and so a reused pid starts from its own counters, not the old ones.
    func forget(pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        lock.lock()
        for pid in pids { latest.removeValue(forKey: pid) }
        lock.unlock()
    }

    func snapshot() -> [Int32: Sample] {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    private func sampleOnce() {
        // -P process mode, -x non-interactive log output, -l 1 one sample,
        // -J restrict columns. nettop is resolved via PATH rather than a
        // hardcoded /usr/bin or /usr/sbin.
        let (output, error) = Self.run(["nettop", "-P", "-x", "-l", "1", "-J", "bytes_in,bytes_out"])
        var rows: [Row] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if let row = Self.parseRow(raw) { rows.append(row) }
        }
        guard !rows.isEmpty else {
            failedRuns += 1
            guard failedRuns >= 5, !reportedFailure else { return }
            reportedFailure = true
            let detail = (error ?? output).trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if let error {
                message = "无法运行 nettop：\(error)"
            } else if detail.isEmpty {
                message = "nettop 没有任何输出。可能需要在系统设置的隐私权限中允许。"
            } else {
                message = "nettop 有输出，但没有能识别的数据行 —— 该 macOS 版本的格式与预期不同。开头几行：\(detail.prefix(240))"
            }
            onStatusChange?(.degraded(message))
            return
        }
        failedRuns = 0
        reportedFailure = false
        lock.lock()
        for row in rows {
            latest[row.pid] = Sample(pid: row.pid, command: row.command,
                                     bytesInCumKB: row.bytesIn / 1024,
                                     bytesOutCumKB: row.bytesOut / 1024)
        }
        lock.unlock()
    }

    /// Runs `/usr/bin/env <arguments>` to completion, killing it after
    /// `timeout`. Returns its output, and an error message when it couldn't
    /// be started or exited with a failure. stderr shares stdout's pipe: a
    /// separate, unread pipe that filled up would block nettop, and its
    /// complaints are what the error message needs.
    static func run(_ arguments: [String], timeout: TimeInterval = 5) -> (output: String, error: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return ("", error.localizedDescription) }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus != 0 else { return (output, nil) }
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output, detail.isEmpty ? "退出码 \(p.terminationStatus)" : String(detail.suffix(300)))
    }

    /// One sample of every process's connections. -n keeps
    /// remotes as addresses: nettop's own lookups swap a connection's IP for
    /// a name between samples, which would read as a new connection.
    static func readConnections() -> [Int32: Sample]? {
        let (output, error) = run(["nettop", "-n", "-x", "-l", "1", "-J", "bytes_in,bytes_out"])
        guard error == nil else { return nil }
        return parseConnectionSample(output)
    }

    static func parseConnectionSample(_ text: String) -> [Int32: Sample] {
        var result: [Int32: Sample] = [:]
        var current: Sample?
        for line in text.split(whereSeparator: \.isNewline) {
            switch parseLine(String(line)) {
            case .process(let row):
                if let current { result[current.pid] = current }
                current = Sample(pid: row.pid, command: row.command,
                                 bytesInCumKB: row.bytesIn / 1024, bytesOutCumKB: row.bytesOut / 1024)
            case .connection(let key, let connection):
                current?.connections[key] = connection
            case .other:
                break
            }
        }
        if let current { result[current.pid] = current }
        return result
    }

    enum Line: Equatable {
        case process(Row)
        case connection(key: String, Connection)
        case other
    }

    /// Classifies one line of per-connection output:
    ///
    ///     Google Chrome H.1836                    9087000          372112
    ///        tcp4 192.168.1.5:49753<->142.250.1.1:443   19025   20590
    ///        udp6 *.5353<->*.*
    ///
    /// Connection rows are indented and name a protocol and `local<->remote`;
    /// a connection with no traffic yet may have no counters at all.
    static func parseLine(_ line: String) -> Line {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .other }
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count >= 2, tokens[0].hasPrefix("tcp") || tokens[0].hasPrefix("udp"),
           let arrow = tokens[1].range(of: "<->") {
            let remote = splitEndpoint(String(tokens[1][arrow.upperBound...]))
            let local = splitEndpoint(String(tokens[1][..<arrow.lowerBound]))
            var bytesIn = 0.0, bytesOut = 0.0
            if tokens.count >= 4, let i = Double(tokens[tokens.count - 2]), let o = Double(tokens[tokens.count - 1]) {
                bytesIn = i
                bytesOut = o
            }
            return .connection(key: tokens[0] + " " + tokens[1],
                               Connection(remoteHost: remote.host, remotePort: remote.port,
                                          bytesIn: bytesIn, bytesOut: bytesOut, localPort: local.port))
        }
        if let row = parseRow(raw) { return .process(row) }
        return .other
    }

    /// nettop writes IPv4 as `addr:port` but IPv6 as `addr.port` (no
    /// brackets), and an unconnected end as `*:*` or `*.*`.
    static func splitEndpoint(_ endpoint: String) -> (host: String, port: Int?) {
        let colons = endpoint.filter { $0 == ":" }.count
        let separator: Character = colons == 1 ? ":" : "."
        guard let cut = endpoint.lastIndex(of: separator) else { return (endpoint, nil) }
        var host = String(endpoint[..<cut])
        // Link-local scope ("fe80::1%en0") means nothing to a lookup.
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        return (host.isEmpty ? "*" : host, Int(endpoint[endpoint.index(after: cut)...]))
    }

    struct Row: Equatable {
        let command: String
        let pid: Int32
        let bytesIn: Double
        let bytesOut: Double
    }

    /// Whitespace is the real separator; the comma path is kept because
    /// nettop's logging mode does emit CSV in some invocations, and splitting
    /// on the wrong one silently yields a single unparsable cell.
    static func parseRow(_ raw: String) -> Row? {
        if raw.contains(",") {
            let fields = raw.components(separatedBy: ",")
            guard let (command, pid) = processCell(in: fields) else { return nil }
            let numbers = fields.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count >= 2 else { return nil }
            return Row(command: command, pid: pid,
                       bytesIn: numbers[numbers.count - 2],
                       bytesOut: numbers[numbers.count - 1])
        }

        // In the whitespace layout the last two cells are the counters and
        // *everything* before them is the name cell — process names contain
        // spaces ("Google Chrome H.1836"), so scanning token by token would
        // match only the trailing "H.1836" and label the row "H".
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 3,
              let bytesOut = Double(tokens[tokens.count - 1]),
              let bytesIn = Double(tokens[tokens.count - 2]) else { return nil }
        let nameCell = tokens[0..<(tokens.count - 2)].joined(separator: " ")
        guard let (command, pid) = processCell(in: [nameCell]) else { return nil }
        return Row(command: command, pid: pid, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    /// Finds the `"ProcessName.PID"` cell in a row. Some macOS versions put it
    /// first, others lead with an empty or timestamp cell, so scan rather than
    /// assume a position — and skip cells that only look the part, like the
    /// `12:00:00.123456` timestamp, which also ends in a dot and digits.
    private static func processCell(in fields: [String]) -> (command: String, pid: Int32)? {
        for field in fields {
            let cell = field.trimmingCharacters(in: .whitespaces)
            guard !cell.contains(":"), let dot = cell.lastIndex(of: ".") else { continue }
            let digits = cell[cell.index(after: dot)...]
            guard (1...7).contains(digits.count), digits.allSatisfy(\.isNumber),
                  let pid = Int32(digits), pid > 0 else { continue }
            let command = String(cell[cell.startIndex..<dot])
            guard !command.isEmpty else { continue }
            return (command, pid)
        }
        return nil
    }
}
