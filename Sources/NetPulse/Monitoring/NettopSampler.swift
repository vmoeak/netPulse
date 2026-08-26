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

    func start() {
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
            let stderrText = String(data: self.stderrBuffer, encoding: .utf8) ?? ""
            self.didReportHardFailure = true
            self.lock.unlock()
            self.watchdogWorkItem?.cancel()
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty
                ? "它可能需要更高权限，或此 Mac 上路径不同。"
                : "nettop 输出：\(detail.suffix(400))"
            self.onStatusChange?(.unavailable("nettop 已退出（code \(proc.terminationStatus)）。\(suffix)"))
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
        let raw = line.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }

        lock.lock()
        sawAnyOutput = true
        if firstLines.count < 3 { firstLines.append(String(raw.prefix(120))) }
        lock.unlock()

        // Whitespace is the real separator; the comma path is kept because
        // nettop's own logging mode does emit CSV in some invocations, and
        // splitting on the wrong one silently yields a single unparsable cell.
        let fields: [String] = raw.contains(",")
            ? raw.components(separatedBy: ",")
            : raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let (command, pid) = Self.processCell(in: fields) else { return }

        let numericFields = fields.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numericFields.count >= 2 else { return }
        let bytesIn = numericFields[numericFields.count - 2]
        let bytesOut = numericFields[numericFields.count - 1]

        lock.lock()
        latest[pid] = Sample(pid: pid, command: command, bytesInCumKB: bytesIn / 1024, bytesOutCumKB: bytesOut / 1024)
        lock.unlock()
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
