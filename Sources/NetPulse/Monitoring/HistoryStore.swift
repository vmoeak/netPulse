import AppKit

/// Persists per-day cumulative KB per app to a JSON file under Application
/// Support, so 本周/本月/全部 rollups survive relaunches. Today's bucket is
/// updated incrementally as live deltas arrive from `NetworkMonitorEngine`.
final class HistoryStore {
    private struct DailyTotals: Codable {
        var downKB: Double
        var upKB: Double
    }

    /// One host's bytes for one app on one day, under the name and kind it
    /// was shown with.
    struct HostRecord: Codable, Equatable {
        var downKB: Double
        var upKB: Double
        var kind: String
    }

    /// This launch's bytes for one endpoint key (a raw IP, `localhost:<port>`,
    /// …) and the name it currently reads as, which a later reverse-DNS
    /// answer can still change.
    private struct LiveHost {
        var downKB = 0.0
        var upKB = 0.0
        var host: String
        var kind: String
    }

    /// [yyyy-MM-dd: [appID: totals]]
    private var days: [String: [String: DailyTotals]] = [:]
    /// appID -> display name, so an app that isn't running can still be
    /// listed by name. Kept in its own file so history.json's format (and
    /// every existing copy of it) stays as it was.
    private var names: [String: String] = [:]
    /// Per-host bytes saved by earlier launches: [day: [appID: [host: record]]].
    /// Never added to while running, so saving can rewrite a day as this
    /// plus `liveHosts` without counting anything twice.
    private var savedHosts: [String: [String: [String: HostRecord]]] = [:]
    /// This launch's per-host bytes: [day: [appID: [endpoint: bytes]]].
    private var liveHosts: [String: [String: [String: LiveHost]]] = [:]
    /// Days whose host file needs rewriting.
    private var dirtyHostDays: Set<String> = []
    private let fileURL: URL
    private let namesURL: URL
    /// One file per day, so a save rewrites only today's hosts rather than
    /// every host ever seen.
    private let hostsDir: URL
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
        hostsDir = dir.appendingPathComponent("hosts", isDirectory: true)
        try? FileManager.default.createDirectory(at: hostsDir, withIntermediateDirectories: true)
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

    /// Adds bytes an app moved to one endpoint today. `host` and `kind` are
    /// how the endpoint reads now; the latest call's label wins.
    func addHostDelta(appID: String, endpoint: String, host: String, kind: String, downKB: Double, upKB: Double) {
        guard downKB > 0 || upKB > 0 else { return }
        let key = dayKey()
        var entry = liveHosts[key]?[appID]?[endpoint] ?? LiveHost(host: host, kind: kind)
        entry.downKB += downKB
        entry.upKB += upKB
        entry.host = host
        entry.kind = kind
        liveHosts[key, default: [:]][appID, default: [:]][endpoint] = entry
        dirtyHostDays.insert(key)
        dirty = true
    }

    /// Renames every endpoint this launch has bytes for, e.g. once an IP's
    /// reverse lookup comes back; the bytes move to the new name.
    func relabelHosts(_ label: (_ endpoint: String) -> (host: String, kind: String)?) {
        for (day, apps) in liveHosts {
            for (appID, endpoints) in apps {
                for (endpoint, entry) in endpoints {
                    guard let new = label(endpoint), new.host != entry.host || new.kind != entry.kind else { continue }
                    liveHosts[day]?[appID]?[endpoint]?.host = new.host
                    liveHosts[day]?[appID]?[endpoint]?.kind = new.kind
                    dirtyHostDays.insert(day)
                    dirty = true
                }
            }
        }
    }

    /// An app's bytes per host over `range`, earlier launches included.
    func hostTotals(appID: String, range: TimeRange) -> [String: HostRecord] {
        hostTotalsByApp(range: range, only: appID)[appID] ?? [:]
    }

    /// Every app's bytes per host over `range`: [appID: [host: record]].
    func hostTotalsByApp(range: TimeRange, only appID: String? = nil) -> [String: [String: HostRecord]] {
        var result: [String: [String: HostRecord]] = [:]
        for key in dayKeys(range) {
            for (app, hosts) in hostsOfDay(key, only: appID) {
                for (host, record) in hosts {
                    var sum = result[app]?[host] ?? HostRecord(downKB: 0, upKB: 0, kind: record.kind)
                    sum.downKB += record.downKB
                    sum.upKB += record.upKB
                    result[app, default: [:]][host] = sum
                }
            }
        }
        return result
    }

    /// One day's hosts: what earlier launches saved plus this launch's bytes
    /// under their current names.
    private func hostsOfDay(_ key: String, only appID: String? = nil) -> [String: [String: HostRecord]] {
        var result: [String: [String: HostRecord]]
        let live: [String: [String: LiveHost]]
        if let appID {
            result = savedHosts[key]?[appID].map { [appID: $0] } ?? [:]
            live = liveHosts[key]?[appID].map { [appID: $0] } ?? [:]
        } else {
            result = savedHosts[key] ?? [:]
            live = liveHosts[key] ?? [:]
        }
        for (app, endpoints) in live {
            for entry in endpoints.values {
                var record = result[app]?[entry.host] ?? HostRecord(downKB: 0, upKB: 0, kind: entry.kind)
                record.downKB += entry.downKB
                record.upKB += entry.upKB
                record.kind = entry.kind
                result[app, default: [:]][entry.host] = record
            }
        }
        return result
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
        let files = (try? FileManager.default.contentsOfDirectory(at: hostsDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let hosts = try? JSONDecoder().decode([String: [String: HostRecord]].self, from: data) else { continue }
            savedHosts[file.deletingPathExtension().lastPathComponent] = hosts
        }
        purgeCommandLineIDs()
    }

    /// Builds before process names were taken from the executable could
    /// save a retitled command line — arguments, tokens and all — as an
    /// app id. Those rows are dropped rather than kept on disk.
    private func purgeCommandLineIDs() {
        // "pid.<n>" ids came from bundle-less apps, named by their process
        // title; a pid means nothing after a relaunch anyway.
        func leaky(_ id: String) -> Bool {
            id.hasPrefix("pid.")
                || (id.hasPrefix("proc.") && ProcessDirectory.looksLikeCommandLine(String(id.dropFirst("proc.".count))))
        }
        let before = names.count + days.values.reduce(0) { $0 + $1.count }
        names = names.filter { !leaky($0.key) && !ProcessDirectory.looksLikeCommandLine($0.value) }
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
        for day in dirtyHostDays {
            // Hosts that never reached 1 KB aren't listed anyway.
            let hosts = hostsOfDay(day).mapValues { $0.filter { $0.value.downKB + $0.value.upKB >= 1 } }
                .filter { !$0.value.isEmpty }
            guard let data = try? JSONEncoder().encode(hosts) else { continue }
            try? data.write(to: hostsDir.appendingPathComponent(day + ".json"), options: .atomic)
        }
        dirtyHostDays = []
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
