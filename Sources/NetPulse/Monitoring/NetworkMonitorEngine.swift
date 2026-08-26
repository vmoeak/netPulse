import Foundation

/// Orchestrates the live monitors into the `apps`/`selectedApp`/etc. state
/// the UI binds to — the real-data analogue of `renderVals()` in the
/// original design's mock, but driven by actual `nettop`/`lsof` sampling
/// instead of `Math.random()`.
@MainActor
final class NetworkMonitorEngine: ObservableObject {
    @Published private(set) var apps: [AppUsage] = []
    @Published var selectedAppID: String?
    @Published var sortMode: SortMode = .rate { didSet { resort() } }
    @Published var range: TimeRange = .today { didSet { resort() } }
    @Published var popoverOpen: Bool = true
    @Published var searchText: String = ""
    @Published private(set) var status: MonitoringStatus = .starting

    private let nettop = NettopSampler()
    private let connections = ConnectionSampler()
    private let dns = ReverseDNSResolver()
    private let history = HistoryStore()

    /// Per-pid cumulative counters from the previous tick, to derive deltas.
    private var previousSamples: [Int32: NettopSampler.Sample] = [:]
    /// pid -> stable app identity, resolved once per pid.
    private var appIdentity: [Int32: ProcessDirectory.Identity] = [:]
    /// Latest per-pid connection info, refreshed every few seconds.
    private var latestConnections: [Int32: ConnectionInfo] = [:]
    /// Resolved hostnames for remote IPs seen so far.
    private var resolvedHosts: [String: String] = [:]

    private var tickTimer: Timer?
    private var hasStarted = false

    /// Idempotent — safe to call from multiple view lifecycle hooks (the
    /// menu bar label appears at launch; the main window may appear later
    /// or not at all), since monitoring should run continuously regardless
    /// of which UI surface is currently visible.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        nettop.onStatusChange = { [weak self] newStatus in
            Task { @MainActor in self?.status = newStatus }
        }
        connections.onSample = { [weak self] infos in
            Task { @MainActor in self?.ingestConnections(infos) }
        }
        connections.onStatusChange = { [weak self] newStatus in
            Task { @MainActor in
                // Don't let a transient lsof hiccup override a hard nettop failure.
                if case .unavailable = self?.status ?? .starting { return }
                self?.status = newStatus
            }
        }
        nettop.start()
        connections.start()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        nettop.stop()
        connections.stop()
        history.saveIfDirty()
    }

    func select(appID: String) { selectedAppID = appID }
    func togglePopover() { popoverOpen.toggle() }
    func openMainWindow() { popoverOpen = false }

    func togglePause(appID: String) {
        guard let idx = apps.firstIndex(where: { $0.id == appID }) else { return }
        apps[idx].isPaused.toggle()
    }

    // MARK: - Derived state consumed by views

    var filteredApps: [AppUsage] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var selectedApp: AppUsage? {
        apps.first(where: { $0.id == selectedAppID }) ?? apps.first
    }

    var topApp: AppUsage? {
        apps.max(by: { ($0.rateDownKBps + $0.rateUpKBps) < ($1.rateDownKBps + $1.rateUpKBps) })
    }

    var popoverList: [AppUsage] {
        let sorted = apps.sorted { ($0.rateDownKBps + $0.rateUpKBps) > ($1.rateDownKBps + $1.rateUpKBps) }
        return Array(sorted.dropFirst().prefix(4))
    }

    var totalDownKBps: Double { apps.reduce(0) { $0 + $1.rateDownKBps } }
    var totalUpKBps: Double { apps.reduce(0) { $0 + $1.rateUpKBps } }
    var totalDownPct: Double { min(1, totalDownKBps / 12_000) }
    var totalUpPct: Double { min(1, totalUpKBps / 8_000) }
    var connectionCount: Int { apps.reduce(0) { $0 + $1.connectionCount } }

    // MARK: - Sampling

    private func ingestConnections(_ infos: [ConnectionInfo]) {
        for info in infos { latestConnections[info.pid] = info }
        let seenIPs = Set(infos.flatMap { Array($0.remoteCounts.keys) })
        let unresolved = seenIPs.subtracting(resolvedHosts.keys)
        guard !unresolved.isEmpty else { return }
        Task {
            for ip in unresolved {
                let host = await dns.resolve(ip)
                await MainActor.run { self.resolvedHosts[ip] = host }
            }
        }
    }

    private func tick() {
        let samples = nettop.snapshot()
        guard !samples.isEmpty else {
            if status == .ok { status = .degraded("等待 nettop 数据…") }
            return
        }
        if status != .ok { status = .ok }

        let pausedIDs = Set(apps.filter(\.isPaused).map(\.id))
        var aggregates: [String: Aggregate] = [:]

        for (pid, sample) in samples {
            let identity = appIdentity[pid] ?? {
                let resolved = ProcessDirectory.identify(pid: pid, fallbackCommand: sample.command)
                appIdentity[pid] = resolved
                return resolved
            }()
            guard !pausedIDs.contains(identity.id) else { continue }

            let prev = previousSamples[pid]
            let downDeltaKB = max(0, sample.bytesInCumKB - (prev?.bytesInCumKB ?? sample.bytesInCumKB))
            let upDeltaKB = max(0, sample.bytesOutCumKB - (prev?.bytesOutCumKB ?? sample.bytesOutCumKB))

            var agg = aggregates[identity.id] ?? Aggregate(name: identity.name, bundleID: identity.bundleID, statusHint: identity.statusHint)
            // One-second tick, so a KB delta this tick is also KB/s.
            agg.downKBps += downDeltaKB
            agg.upKBps += upDeltaKB
            agg.pids.append(pid)
            aggregates[identity.id] = agg

            history.addDelta(appID: identity.id, downKB: downDeltaKB, upKB: upDeltaKB)
        }
        previousSamples = samples

        var next: [String: AppUsage] = [:]
        for (id, agg) in aggregates {
            next[id] = buildUsage(id: id, agg: agg)
        }
        for existing in apps where next[existing.id] == nil {
            next[existing.id] = existing // e.g. paused, or nettop skipped it this tick
        }

        apps = next.values.sorted(by: comparator(for: sortMode, range: range))
        if let sel = selectedAppID, next[sel] != nil {
            // keep selection
        } else {
            selectedAppID = apps.first?.id
        }
    }

    private struct Aggregate {
        var name: String
        var bundleID: String
        var statusHint: String
        var downKBps: Double = 0
        var upKBps: Double = 0
        var pids: [Int32] = []
    }

    private func buildUsage(id: String, agg: Aggregate) -> AppUsage {
        var usage = apps.first(where: { $0.id == id }) ?? AppUsage(
            id: id, name: agg.name, bundleID: agg.bundleID,
            badge: AppPalette.badge(bundleID: agg.bundleID, name: agg.name),
            connectionCount: 0, statusLine: agg.statusHint,
            rateDownKBps: 0, rateUpKBps: 0,
            totalDownKB: [:], totalUpKB: [:],
            downHistory: [], upHistory: [], domains: [], isPaused: false
        )
        usage.statusLine = agg.statusHint
        usage.rateDownKBps = agg.downKBps
        usage.rateUpKBps = agg.upKBps
        usage.downHistory = Array((usage.downHistory + [agg.downKBps]).suffix(60))
        usage.upHistory = Array((usage.upHistory + [agg.upKBps]).suffix(60))

        var hostConnCounts: [String: Int] = [:]
        for pid in agg.pids {
            guard let info = latestConnections[pid] else { continue }
            for (ip, count) in info.remoteCounts {
                hostConnCounts[ip, default: 0] += count
            }
        }
        usage.connectionCount = hostConnCounts.values.reduce(0, +)
        let totalConns = max(1, usage.connectionCount)
        let previousDomains = usage.domains
        usage.domains = hostConnCounts.map { ip, count -> DomainUsage in
            let host = resolvedHosts[ip] ?? ip
            let share = Double(count) / Double(totalConns)
            let existing = previousDomains.first(where: { $0.host == host })
            return DomainUsage(
                host: host,
                kind: host == ip ? "IP 地址" : "已解析主机",
                rateDownKBps: agg.downKBps * share,
                totalDownKB: (existing?.totalDownKB ?? 0) + agg.downKBps * share,
                totalUpKB: (existing?.totalUpKB ?? 0) + agg.upKBps * share,
                connectionCount: count
            )
        }.sorted { $0.connectionCount > $1.connectionCount }

        for r in TimeRange.allCases {
            let rolled = history.rollup(appID: id, range: r)
            usage.totalDownKB[r] = rolled.downKB
            usage.totalUpKB[r] = rolled.upKB
        }
        return usage
    }

    private func resort() {
        apps = apps.sorted(by: comparator(for: sortMode, range: range))
    }

    private func comparator(for sortMode: SortMode, range: TimeRange) -> (AppUsage, AppUsage) -> Bool {
        { lhs, rhs in
            if sortMode == .rate {
                return (lhs.rateDownKBps + lhs.rateUpKBps) > (rhs.rateDownKBps + rhs.rateUpKBps)
            }
            let l = (lhs.totalDownKB[range] ?? 0) + (lhs.totalUpKB[range] ?? 0)
            let r = (rhs.totalDownKB[range] ?? 0) + (rhs.totalUpKB[range] ?? 0)
            return l > r
        }
    }
}
