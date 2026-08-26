import Foundation

/// Streams per-process network byte counters from the built-in `nettop`
/// tool (no special entitlement needed, unlike the Network Extension APIs
/// that would give the mockup's precision).
///
/// NOTE ON FORMAT ASSUMPTIONS: this parser was written against documented
/// `nettop` behavior and has not been run against a live macOS box in this
/// environment. It expects each data row's first CSV field to look like
/// `"ProcessName.PID"` and treats the last two numeric-looking fields on
/// the line as cumulative bytes-in/bytes-out. If real output doesn't match
/// (e.g. a different field order), the watchdog in `armWatchdog()` below
/// will flip `status` to `.degraded` after 5s of no parsed rows instead of
/// silently showing all-zero data — check Console output and adjust
/// `parse(line:)` first.
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
    private var buffer = Data()
    private let newline = Data([0x0A])
    private let lock = NSLock()
    private var latest: [Int32: Sample] = [:]
    private var watchdogWorkItem: DispatchWorkItem?

    func start() {
        let p = Process()
        // Resolved via PATH rather than a hardcoded /usr/bin or /usr/sbin —
        // both are plausible for nettop and this avoids guessing wrong.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // -P process mode, -x non-interactive log output (safe to pipe),
        // -l 0 sample forever, -s 1 once per second, -J restrict columns.
        p.arguments = ["nettop", "-P", "-x", "-l", "0", "-s", "1", "-J", "bytes_in,bytes_out"]

        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe() // discarded

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        p.terminationHandler = { [weak self] proc in
            self?.onStatusChange?(.unavailable("nettop 已退出（code \(proc.terminationStatus)）。它可能需要更高权限，或此 Mac 上路径不同。"))
        }

        do {
            try p.run()
            process = p
            outputPipe = out
            armWatchdog()
        } catch {
            onStatusChange?(.unavailable("无法启动 nettop：\(error.localizedDescription)"))
        }
    }

    func stop() {
        watchdogWorkItem?.cancel()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        outputPipe = nil
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
            self.lock.unlock()
            if empty {
                self.onStatusChange?(.degraded("nettop 5 秒内未返回任何数据。可能需要在系统设置的隐私权限中允许，或该 macOS 版本的输出格式与预期不同。"))
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
        let fields = raw.components(separatedBy: ",")
        guard let first = fields.first, let dot = first.lastIndex(of: ".") else { return }
        let pidString = first[first.index(after: dot)...]
        guard let pid = Int32(pidString) else { return }
        let command = String(first[first.startIndex..<dot])

        let numericFields = fields.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numericFields.count >= 2 else { return }
        let bytesIn = numericFields[numericFields.count - 2]
        let bytesOut = numericFields[numericFields.count - 1]

        lock.lock()
        latest[pid] = Sample(pid: pid, command: command, bytesInCumKB: bytesIn / 1024, bytesOutCumKB: bytesOut / 1024)
        lock.unlock()
    }
}
