import AppKit

/// Persists per-day cumulative KB per app to a JSON file under Application
/// Support, so 本周/本月/全部 rollups survive relaunches. Today's bucket is
/// updated incrementally as live deltas arrive from `NetworkMonitorEngine`.
final class HistoryStore {
    private struct DailyTotals: Codable {
        var downKB: Double
        var upKB: Double
    }

    /// [yyyy-MM-dd: [appID: totals]]
    private var days: [String: [String: DailyTotals]] = [:]
    /// appID -> display name, so an app that isn't running can still be
    /// listed by name. Kept in its own file so history.json's format (and
    /// every existing copy of it) stays as it was.
    private var names: [String: String] = [:]
    private let fileURL: URL
    private let namesURL: URL
    private let calendar = Calendar.current
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private var dirty = false
    private var saveTimer: Timer?
    private var terminationObserver: NSObjectProtocol?

    /// `directory` is for tests; the app stores under Application Support.
    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = directory ?? base.appendingPathComponent("NetPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        namesURL = dir.appendingPathComponent("app-names.json")
        load()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.saveIfDirty()
        }
        // Nothing else saves on quit, so up to 15 seconds of traffic went
        // missing from the totals every time the app was closed. Posted on
        // the main thread, where every other access to `days` happens.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveIfDirty()
        }
    }

    private func dayKey(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    func addDelta(appID: String, downKB: Double, upKB: Double) {
        guard downKB > 0 || upKB > 0 else { return }
        let key = dayKey()
        var todays = days[key] ?? [:]
        var totals = todays[appID] ?? DailyTotals(downKB: 0, upKB: 0)
        totals.downKB += downKB
        totals.upKB += upKB
        todays[appID] = totals
        days[key] = todays
        dirty = true
    }

    func rememberName(_ name: String, for appID: String) {
        guard names[appID] != name else { return }
        names[appID] = name
        dirty = true
    }

    func name(for appID: String) -> String? { names[appID] }

    /// Every app's totals over `range` in one pass, for listing apps that
    /// aren't running — cheaper than a `rollup` per app.
    func totalsByApp(range: TimeRange) -> [String: (downKB: Double, upKB: Double)] {
        var result: [String: (downKB: Double, upKB: Double)] = [:]
        for key in dayKeys(range) {
            guard let apps = days[key] else { continue }
            for (appID, t) in apps {
                let prev = result[appID] ?? (0, 0)
                result[appID] = (prev.downKB + t.downKB, prev.upKB + t.upKB)
            }
        }
        return result
    }

    private func dayKeys(_ range: TimeRange) -> [String] {
        let daysBack: Int
        switch range {
        case .all: return Array(days.keys)
        case .today: daysBack = 0
        case .week: daysBack = 6
        case .month: daysBack = 29
        }
        let today = Date()
        return (0...daysBack).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { dayKey($0) }
        }
    }

    /// Sums stored totals for `appID` over `range`. `.today` is exactly
    /// today's bucket, which is always kept up to date with this launch's
    /// live deltas even before the first periodic save.
    func rollup(appID: String, range: TimeRange) -> (downKB: Double, upKB: Double) {
        var down = 0.0, up = 0.0
        for key in dayKeys(range) {
            if let t = days[key]?[appID] { down += t.downKB; up += t.upKB }
        }
        return (down, up)
    }

    private func load() {
        if let data = try? Data(contentsOf: namesURL) {
            names = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: fileURL) {
            days = (try? JSONDecoder().decode([String: [String: DailyTotals]].self, from: data)) ?? [:]
        }
        purgeCommandLineIDs()
    }

    /// Builds before process names were taken from the executable could
    /// save a retitled command line — arguments, tokens and all — as an
    /// app id. Those rows are dropped rather than kept on disk.
    private func purgeCommandLineIDs() {
        func leaky(_ id: String) -> Bool { id.hasPrefix("proc.") && id.contains(" -") }
        let before = names.count + days.values.reduce(0) { $0 + $1.count }
        names = names.filter { !leaky($0.key) }
        days = days.mapValues { $0.filter { !leaky($0.key) } }
        if names.count + days.values.reduce(0, { $0 + $1.count }) != before {
            dirty = true
            saveIfDirty()
        }
    }

    func saveIfDirty() {
        guard dirty else { return }
        dirty = false
        if let data = try? JSONEncoder().encode(names) {
            try? data.write(to: namesURL, options: .atomic)
        }
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
