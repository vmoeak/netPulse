import Foundation

/// Streams per-process network byte counters from the built-in `nettop`
/// tool (no special entitlement needed, unlike the Network Extension APIs
/// that would give the mockup's precision).
///
/// ROW FORMAT: `nettop -x` writes whitespace-aligned columns, not CSV —
///
///     mDNSResponder.595                       9087000          372112
///
/// with the process name truncated to 15 characters (which only affects
/// daemons; GUI apps are renamed from their pid via `ProcessDirectory`).
/// `parse(line:)` scans a row's cells for the `"ProcessName.PID"` one
/// rather than assuming a position, and reads the last two numeric cells as
/// cumulative bytes-in/bytes-out. `-x` keeps those unabbreviated, so there
/// are no K/M suffixes to interpret.
///
/// When nothing parses, the status message says which of the two failure
/// modes happened — nettop produced no output at all, or it produced output
/// no row of which was recognizable (in which case the message quotes the
/// first line, so the real format can be read off the UI) — and a nettop
/// that dies on startup reports its own stderr instead.
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

        var isLoopback: Bool {
            remoteHost == "::1" || remoteHost == "localhost" || remoteHost.hasPrefix("127.")
                || remoteHost.hasPrefix("::ffff:127.")
        }
    }

    var onStatusChange: ((MonitoringStatus) -> Void)?

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var buffer = Data()
    private let newline = Data([0x0A])
    private let lock = NSLock()
    private var latest: [Int32: Sample] = [:]
    private var watchdogWorkItem: DispatchWorkItem?
    /// Diagnostics for the watchdog, all guarded by `lock`: whether nettop
    /// wrote anything at all, the first few lines verbatim (so an unexpected
    /// format can be reported instead of guessed at), whatever it put on
    /// stderr, and whether a hard failure was already surfaced.
    private var sawAnyOutput = false
    private var firstLines: [String] = []
    private var stderrBuffer = Data()
    private var didReportHardFailure = false
    private var parsedAnyRow = false

    /// How many times in a row nettop has been relaunched without producing
    /// a row in between. Reset once a run has parsed a row, so a nettop that dies
    /// once after hours (sleep/wake does this) always comes back, while one
    /// that can never run stops being retried.
    private var restartAttempts = 0
    private let maxRestartAttempts = 5
    private var stopped = false

    func start() {
        stopped = false
        lock.lock()
        buffer = Data()
        latest = [:]
        sawAnyOutput = false
        firstLines = []
        stderrBuffer = Data()
        didReportHardFailure = false
        parsedAnyRow = false
        lock.unlock()

        let p = Process()
        // nettop writes through stdio, which fully buffers into a pipe: on a
        // quiet Mac a whole buffer takes tens of seconds to fill, so rows
        // arrived in rare bursts and short-lived traffic (a 10 s download)
        // was never seen at all — CI's smoke test caught this. Running it
        // under `script` gives it a pseudo-terminal, where stdio flushes
        // every line. `script` copies the terminal's output to our pipe
        // unbuffered, and closing it hangs up nettop.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // nettop is resolved via PATH rather than a hardcoded /usr/bin or
        // /usr/sbin — both are plausible and this avoids guessing wrong.
        // -P process mode, -x non-interactive log output, -l 0 sample
        // forever, -s 1 once per second, -J restrict columns. Connections
        // are read separately and less often (`readConnections()`): streamed
        // every second they kept nettop at over 100% CPU.
        p.arguments = ["-q", "/dev/null",
                       "/usr/bin/env", "nettop", "-P", "-x", "-l", "0", "-s", "1", "-J", "bytes_in,bytes_out"]

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        // Kept rather than discarded: when nettop rejects an argument or lacks
        // permission it says so here and then exits, and that message is far
        // more useful than the watchdog's generic "no data" guess.
        p.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            self.stderrBuffer.append(data)
            if self.stderrBuffer.count > 4096 {
                self.stderrBuffer.removeFirst(self.stderrBuffer.count - 4096)
            }
            self.lock.unlock()
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            // Under the pseudo-terminal nettop's own errors arrive on stdout,
            // so its first lines stand in when `script` itself said nothing.
            var stderrText = String(data: self.stderrBuffer, encoding: .utf8) ?? ""
            if stderrText.isEmpty { stderrText = self.firstLines.joined(separator: " ⏎ ") }
            self.didReportHardFailure = true
            let wasProducingRows = self.parsedAnyRow
            self.lock.unlock()
            self.watchdogWorkItem?.cancel()
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty
                ? "它可能需要更高权限，或此 Mac 上路径不同。"
                : "nettop 输出：\(detail.suffix(400))"
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                if wasProducingRows { self.restartAttempts = 0 }
                if self.restartAttempts < self.maxRestartAttempts {
                    self.restartAttempts += 1
                    self.onStatusChange?(.degraded("nettop 已退出（code \(code)），正在重新启动…"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guard !self.stopped else { return }
                        self.teardown()
                        self.start()
                    }
                } else {
                    self.onStatusChange?(.unavailable("nettop 已退出（code \(code)）。\(suffix)"))
                }
            }
        }

        do {
            try p.run()
            process = p
            outputPipe = out
            errorPipe = err
            armWatchdog()
        } catch {
            onStatusChange?(.unavailable("无法启动 nettop：\(error.localizedDescription)"))
        }
    }

    func stop() {
        stopped = true
        teardown()
    }

    /// Drops dead pids so their last counters stop being reported forever —
    /// and so a reused pid starts from its own counters, not the old ones.
    func forget(pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        lock.lock()
        for pid in pids { latest.removeValue(forKey: pid) }
        lock.unlock()
    }

    private func teardown() {
        watchdogWorkItem?.cancel()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        outputPipe = nil
        errorPipe = nil
    }

    func snapshot() -> [Int32: Sample] {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    private func armWatchdog() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let empty = self.latest.isEmpty
            // A nettop that already died reported its own stderr; don't paper
            // over that with a vaguer message five seconds later.
            let alreadyReported = self.didReportHardFailure
            let sawOutput = self.sawAnyOutput
            let preview = self.firstLines.joined(separator: " ⏎ ")
            self.lock.unlock()
            guard empty, !alreadyReported else { return }
            if sawOutput {
                self.onStatusChange?(.degraded("nettop 有输出，但没有能识别的数据行 —— 该 macOS 版本的格式与预期不同。开头几行：\(preview)"))
            } else {
                self.onStatusChange?(.degraded("nettop 5 秒内没有任何输出。可能需要在系统设置的隐私权限中允许。"))
            }
        }
        watchdogWorkItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8) {
                parse(line: line)
            }
        }
    }

    private func parse(line: String) {
        // A terminal ends lines with \r\n.
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        lock.lock(); defer { lock.unlock() }
        sawAnyOutput = true
        if firstLines.count < 3 { firstLines.append(String(raw.prefix(120))) }
        guard let row = Self.parseRow(raw) else { return }
        latest[row.pid] = Sample(pid: row.pid,
                                 command: row.command,
                                 bytesInCumKB: row.bytesIn / 1024,
                                 bytesOutCumKB: row.bytesOut / 1024)
        parsedAnyRow = true
    }

    /// One sample of every process's connections, from a nettop that exits
    /// right after (so no pseudo-terminal is needed to flush it). -n keeps
    /// remotes as addresses: nettop's own lookups swap a connection's IP for
    /// a name between samples, which would read as a new connection.
    static func readConnections(timeout: TimeInterval = 5) -> [Int32: Sample]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["nettop", "-n", "-x", "-l", "1", "-J", "bytes_in,bytes_out"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return parseConnectionSample(text)
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
            var bytesIn = 0.0, bytesOut = 0.0
            if tokens.count >= 4, let i = Double(tokens[tokens.count - 2]), let o = Double(tokens[tokens.count - 1]) {
                bytesIn = i
                bytesOut = o
            }
            return .connection(key: tokens[0] + " " + tokens[1],
                               Connection(remoteHost: remote.host, remotePort: remote.port,
                                          bytesIn: bytesIn, bytesOut: bytesOut))
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
