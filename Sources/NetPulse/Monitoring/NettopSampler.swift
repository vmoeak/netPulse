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
final class NettopSampler {
    struct Sample {
        let pid: Int32
        let command: String
        /// Cumulative bytes received/sent since the process started, in KB.
        let bytesInCumKB: Double
        let bytesOutCumKB: Double
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
    /// Bumped (under `lock`) on every launch, so output still draining from a
    /// nettop that already exited can't land in the new run's samples.
    private var generation = 0

    /// Main-thread only. A nettop that exits on its own is relaunched after
    /// `restartDelay`, which doubles on each quick failure so one that dies
    /// immediately (e.g. no permission) isn't respawned every second.
    private var isStopped = false
    private var restartDelay: TimeInterval = NettopSampler.minRestartDelay
    private static let minRestartDelay: TimeInterval = 2
    private static let maxRestartDelay: TimeInterval = 60

    func start() {
        isStopped = false
        launch()
    }

    private func launch() {
        let p = Process()
        // Resolved via PATH rather than a hardcoded /usr/bin or /usr/sbin —
        // both are plausible for nettop and this avoids guessing wrong.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // -P process mode, -x non-interactive log output (safe to pipe),
        // -l 0 sample forever, -s 1 once per second, -J restrict columns.
        p.arguments = ["nettop", "-P", "-x", "-l", "0", "-s", "1", "-J", "bytes_in,bytes_out"]

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        // Kept rather than discarded: when nettop rejects an argument or lacks
        // permission it says so here and then exits, and that message is far
        // more useful than the watchdog's generic "no data" guess.
        p.standardError = err

        lock.lock()
        generation += 1
        let gen = generation
        latest = [:]
        buffer = Data()
        sawAnyOutput = false
        firstLines = []
        stderrBuffer = Data()
        didReportHardFailure = false
        lock.unlock()

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data, generation: gen)
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
        let launchedAt = Date()
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            let stderrText = String(data: self.stderrBuffer, encoding: .utf8) ?? ""
            self.didReportHardFailure = true
            // Its counters stop here. Leaving them in `latest` would keep
            // `snapshot()` non-empty, and the engine would go on reading the
            // frozen values as a healthy all-zero feed.
            self.latest = [:]
            self.lock.unlock()
            self.watchdogWorkItem?.cancel()
            let status = proc.terminationStatus
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { [weak self] in
                self?.scheduleRestart(exitStatus: status, stderr: detail, ranFor: Date().timeIntervalSince(launchedAt))
            }
        }

        do {
            try p.run()
            process = p
            outputPipe = out
            errorPipe = err
            armWatchdog()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            onStatusChange?(.unavailable("无法启动 nettop：\(error.localizedDescription)"))
        }
    }

    /// Main thread. A run that lasted a while was healthy, so its exit starts
    /// the backoff over; a quick exit doubles it.
    private func scheduleRestart(exitStatus: Int32, stderr detail: String, ranFor: TimeInterval) {
        guard !isStopped else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outputPipe = nil
        errorPipe = nil

        if ranFor > 30 { restartDelay = Self.minRestartDelay }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, Self.maxRestartDelay)

        let suffix = detail.isEmpty
            ? "它可能需要更高权限，或此 Mac 上路径不同。"
            : "nettop 输出：\(detail.suffix(400))"
        onStatusChange?(.unavailable("nettop 已退出（code \(exitStatus)），\(Int(delay)) 秒后重试。\(suffix)"))

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopped, self.process == nil else { return }
            self.launch()
        }
    }

    func stop() {
        isStopped = true
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

    /// Drops processes that have exited. nettop stops listing a process once
    /// it is gone but never says so, so without this its last row would stay
    /// in `latest` for good.
    func forget(pids: [Int32]) {
        guard !pids.isEmpty else { return }
        lock.lock()
        for pid in pids { latest[pid] = nil }
        lock.unlock()
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

    private func consume(_ data: Data, generation gen: Int) {
        lock.lock()
        let current = gen == generation
        lock.unlock()
        guard current else { return }
        buffer.append(data)
        while let range = buffer.range(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8) {
                parse(line: line, generation: gen)
            }
        }
    }

    private func parse(line: String, generation gen: Int) {
        let raw = line.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }

        lock.lock()
        sawAnyOutput = true
        if firstLines.count < 3 { firstLines.append(String(raw.prefix(120))) }
        lock.unlock()

        guard let row = Self.parseRow(raw) else { return }

        lock.lock()
        defer { lock.unlock() }
        guard gen == generation else { return }
        latest[row.pid] = Sample(pid: row.pid,
                                 command: row.command,
                                 bytesInCumKB: row.bytesIn / 1024,
                                 bytesOutCumKB: row.bytesOut / 1024)
    }

    private struct Row {
        let command: String
        let pid: Int32
        let bytesIn: Double
        let bytesOut: Double
    }

    /// Whitespace is the real separator; the comma path is kept because
    /// nettop's logging mode does emit CSV in some invocations, and splitting
    /// on the wrong one silently yields a single unparsable cell.
    private static func parseRow(_ raw: String) -> Row? {
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
