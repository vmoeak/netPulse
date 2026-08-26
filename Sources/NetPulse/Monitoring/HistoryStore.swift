import Foundation

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
    private let fileURL: URL
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

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("NetPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
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

    /// Sums stored totals for `appID` over `range`. `.today` is exactly
    /// today's bucket, which is always kept up to date with this launch's
    /// live deltas even before the first periodic save.
    func rollup(appID: String, range: TimeRange) -> (downKB: Double, upKB: Double) {
        if range == .all {
            var down = 0.0, up = 0.0
            for apps in days.values {
                if let t = apps[appID] { down += t.downKB; up += t.upKB }
            }
            return (down, up)
        }
        let daysBack: Int
        switch range {
        case .today: daysBack = 0
        case .week: daysBack = 6
        case .month: daysBack = 29
        case .all: daysBack = 0 // unreachable, handled above
        }
        var down = 0.0, up = 0.0
        let today = Date()
        for offset in 0...daysBack {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            if let t = days[dayKey(date)]?[appID] { down += t.downKB; up += t.upKB }
        }
        return (down, up)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        days = (try? JSONDecoder().decode([String: [String: DailyTotals]].self, from: data)) ?? [:]
    }

    func saveIfDirty() {
        guard dirty else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
