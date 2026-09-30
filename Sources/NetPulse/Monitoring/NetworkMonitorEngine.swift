import Foundation

private let pausedAppsDefaultsKey = "pausedAppIDs"

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
    @Published var section: SidebarSection = .apps
    @Published var popoverOpen: Bool = true
    @Published var searchText: String = ""
    @Published private(set) var status: MonitoringStatus = .starting
    /// Machine-wide rates over the last 60 ticks, oldest first — what the
    /// menu bar chip draws and what the sidebar meters are scaled against.
    @Published private(set) var totalDownHistory: [Double] = []
    @Published private(set) var totalUpHistory: [Double] = []

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
    /// Who is listening on which port, so a loopback peer can be named.
    private var latestListeners: [Int: ListenerInfo] = [:]
    /// Resolved hostnames for remote IPs seen so far.
    private var resolvedHosts: [String: String] = [:]
    /// IPs with a reverse lookup already under way, so an lsof pass that
    /// lands before the answer doesn't start a second one.
    private var pendingLookups: Set<String> = []
    /// appID -> endpoint key -> this launch's estimated bytes. Kept apart
    /// from `AppUsage.domains`, which holds only the hosts connected right
    /// now, so a host's total survives its connections closing (and 域名总览
    /// can keep listing it). Keys are the raw endpoint — the remote IP, or
    /// `localhost:<port>` — so a later reverse-DNS answer relabels the row
    /// instead of starting a second one under the new name.
    private var hostTotals: [String: [String: HostTotals]] = [:]
    /// Apps the user excluded from counting. Persisted, so a pause outlives
    /// the app relaunching (or NetPulse restarting).
    private var pausedIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: pausedAppsDefaultsKey) ?? [])
    private var tickCount = 0

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
        connections.onSample = { [weak self] snapshot in
            Task { @MainActor in self?.ingestConnections(snapshot) }
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
            // Timer's block is `@Sendable`, so the `weak self` capture reads as a
            // mutable var there — binding it to an immutable `self` first is what
            // lets the inner `Task` capture it.
            guard let self else { return }
            Task { @MainActor in self.tick() }
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
        if pausedIDs.contains(appID) { pausedIDs.remove(appID) } else { pausedIDs.insert(appID) }
        UserDefaults.standard.set(Array(pausedIDs), forKey: pausedAppsDefaultsKey)
        guard let idx = apps.firstIndex(where: { $0.id == appID }) else { return }
        apps[idx].isPaused = pausedIDs.contains(appID)
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

    /// 活跃连接: every app's hosts flattened into one machine-wide list,
    /// busiest first.
    var connectionRows: [ConnectionRow] {
        apps.flatMap { app in
            app.domains.map { domain in
                ConnectionRow(appID: app.id,
                              appName: app.name,
                              badge: app.badge,
                              host: domain.host,
                              kind: domain.kind,
                              rateDownKBps: domain.rateDownKBps,
                              connectionCount: domain.connectionCount)
            }
        }
        .sorted { ($0.rateDownKBps, $0.connectionCount) > ($1.rateDownKBps, $1.connectionCount) }
    }

    /// 域名总览: the same hosts keyed by host rather than by app, so a CDN
    /// several apps share reads as one row carrying their combined traffic.
    /// Unlike 活跃连接 it also keeps hosts whose connections have closed,
    /// since their totals are what this view ranks by.
    var domainRollups: [DomainRollup] {
        var byHost: [String: DomainRollup] = [:]
        let names = Dictionary(apps.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for (appID, hosts) in hostTotals {
            guard let appName = names[appID] else { continue }
            for (key, totals) in hosts {
                let (host, kind) = describe(endpoint: key)
                var rollup = byHost[host] ?? DomainRollup(host: host, kind: kind, rateDownKBps: 0,
                                                          totalDownKB: 0, totalUpKB: 0,
                                                          connectionCount: 0, appNames: [])
                rollup.totalDownKB += totals.downKB
                rollup.totalUpKB += totals.upKB
                if !rollup.appNames.contains(appName) { rollup.appNames.append(appName) }
                byHost[host] = rollup
            }
        }
        for app in apps {
            for domain in app.domains {
                byHost[domain.host]?.rateDownKBps += domain.rateDownKBps
                byHost[domain.host]?.connectionCount += domain.connectionCount
            }
        }
        return byHost.values
            .filter { $0.connectionCount > 0 || $0.totalDownKB + $0.totalUpKB >= 1 }
            .sorted { ($0.totalDownKB, $0.rateDownKBps) > ($1.totalDownKB, $1.rateDownKBps) }
    }

    var totalDownKBps: Double { apps.reduce(0) { $0 + $1.rateDownKBps } }
    var totalUpKBps: Double { apps.reduce(0) { $0 + $1.rateUpKBps } }
    /// The sidebar meters read against the last minute's peak rather than a
    /// fixed line speed, which was wrong for any connection but one. The
    /// 1 MB/s floor keeps a trickle from filling the bar.
    var totalDownPct: Double { meterFraction(totalDownKBps, history: totalDownHistory) }
    var totalUpPct: Double { meterFraction(totalUpKBps, history: totalUpHistory) }

    private func meterFraction(_ value: Double, history: [Double]) -> Double {
        min(1, value / max(1024, history.max() ?? 0))
    }
    var connectionCount: Int { apps.reduce(0) { $0 + $1.connectionCount } }

    // MARK: - Sampling

    private func ingestConnections(_ snapshot: ConnectionSnapshot) {
        let infos = snapshot.connections
        // Replaced wholesale, not merged: lsof leaves out a process that has
        // closed its last socket, and merging kept that process's old hosts
        // on screen indefinitely.
        latestConnections = Dictionary(infos.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        latestListeners = snapshot.listeners
        // Loopback peers are deliberately not resolved: reverse DNS answers
        // "localhost" for all of them, which is exactly the useless label the
        // listener lookup exists to replace.
        let seenIPs = Set(infos.flatMap { Array($0.remoteCounts.keys) })
        let unresolved = seenIPs.subtracting(resolvedHosts.keys).subtracting(pendingLookups)
        guard !unresolved.isEmpty else { return }
        pendingLookups.formUnion(unresolved)
        Task {
            for ip in unresolved {
                let host = await dns.resolve(ip)
                await MainActor.run {
                    self.resolvedHosts[ip] = host
                    self.pendingLookups.remove(ip)
                }
            }
        }
    }

    private func tick() {
        tickCount += 1
        if tickCount % 5 == 0 { forgetExitedProcesses() }

        let samples = nettop.snapshot()
        guard !samples.isEmpty else {
            if status == .ok { status = .degraded("等待 nettop 数据…") }
            return
        }
        if status != .ok { status = .ok }

        var aggregates: [String: Aggregate] = [:]
        var pausedRunning: [String: ProcessDirectory.Identity] = [:]

        for (pid, sample) in samples {
            let identity = identify(pid: pid, command: sample.command)
            guard !pausedIDs.contains(identity.id) else {
                pausedRunning[identity.id] = identity
                continue
            }

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
        // Apps with no live process this tick — paused, or every pid exited.
        // Their totals stay; what they were doing a moment ago does not.
        for existing in apps where next[existing.id] == nil {
            if let idle = idleUsage(existing) { next[existing.id] = idle }
        }
        // A pause is remembered across launches, so a paused app can be
        // running without ever having had a row — it still needs one, or
        // there would be nowhere to resume it from.
        for (id, identity) in pausedRunning where next[id] == nil {
            next[id] = idleUsage(newUsage(id: id, name: identity.name, bundleID: identity.bundleID,
                                          statusHint: identity.statusHint))
        }

        apps = next.values.sorted(by: comparator(for: sortMode, range: range))
        totalDownHistory = Array((totalDownHistory + [totalDownKBps]).suffix(60))
        totalUpHistory = Array((totalUpHistory + [totalUpKBps]).suffix(60))
        if let sel = selectedAppID, next[sel] != nil {
            // keep selection
        } else {
            selectedAppID = apps.first?.id
        }
    }

    /// An app row for a tick in which none of its processes reported: rates
    /// and open hosts go to zero, totals are kept. An exited app that never
    /// moved a byte is dropped instead of lingering as an empty row.
    private func idleUsage(_ existing: AppUsage) -> AppUsage? {
        let paused = pausedIDs.contains(existing.id)
        let everMoved = (existing.totalDownKB[.all] ?? 0) + (existing.totalUpKB[.all] ?? 0) > 0
        guard paused || everMoved else { return nil }
        var usage = existing
        usage.isPaused = paused
        usage.statusLine = paused ? "已暂停统计" : "已退出"
        usage.rateDownKBps = 0
        usage.rateUpKBps = 0
        usage.downHistory = Array((usage.downHistory + [0]).suffix(60))
        usage.upHistory = Array((usage.upHistory + [0]).suffix(60))
        usage.domains = []
        usage.connectionCount = 0
        return usage
    }

    private func identify(pid: Int32, command: String) -> ProcessDirectory.Identity {
        if let known = appIdentity[pid] { return known }
        let resolved = ProcessDirectory.identify(pid: pid, fallbackCommand: command)
        appIdentity[pid] = resolved
        return resolved
    }

    /// nettop keeps reporting a pid's last counters after the process is
    /// gone, so without this the per-pid caches only ever grow — and a pid
    /// the system hands to a new process would inherit the old one's app.
    private func forgetExitedProcesses() {
        let known = Set(appIdentity.keys).union(previousSamples.keys)
        let exited = known.filter { kill($0, 0) != 0 && errno == ESRCH }
        guard !exited.isEmpty else { return }
        nettop.forget(pids: exited)
        for pid in exited {
            appIdentity.removeValue(forKey: pid)
            previousSamples.removeValue(forKey: pid)
            latestConnections.removeValue(forKey: pid)
        }
    }

    private struct HostTotals {
        var downKB: Double = 0
        var upKB: Double = 0
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
        var usage = apps.first(where: { $0.id == id })
            ?? newUsage(id: id, name: agg.name, bundleID: agg.bundleID, statusHint: agg.statusHint)
        usage.statusLine = agg.statusHint
        usage.isPaused = false
        usage.rateDownKBps = agg.downKBps
        usage.rateUpKBps = agg.upKBps
        usage.downHistory = Array((usage.downHistory + [agg.downKBps]).suffix(60))
        usage.upHistory = Array((usage.upHistory + [agg.upKBps]).suffix(60))

        var hostConnCounts: [String: Int] = [:]
        var loopbackConnCounts: [Int: Int] = [:]
        for pid in agg.pids {
            guard let info = latestConnections[pid] else { continue }
            for (ip, count) in info.remoteCounts {
                hostConnCounts[ip, default: 0] += count
            }
            for (port, count) in info.loopbackCounts {
                loopbackConnCounts[port, default: 0] += count
            }
        }
        usage.connectionCount = hostConnCounts.values.reduce(0, +)
            + loopbackConnCounts.values.reduce(0, +)
        let totalConns = max(1, usage.connectionCount)
        var appHostTotals = hostTotals[id] ?? [:]

        func domain(endpoint: String, count: Int) -> DomainUsage {
            let share = Double(count) / Double(totalConns)
            var totals = appHostTotals[endpoint] ?? HostTotals()
            totals.downKB += agg.downKBps * share
            totals.upKB += agg.upKBps * share
            appHostTotals[endpoint] = totals
            let (host, kind) = describe(endpoint: endpoint)
            return DomainUsage(
                host: host,
                kind: kind,
                rateDownKBps: agg.downKBps * share,
                totalDownKB: totals.downKB,
                totalUpKB: totals.upKB,
                connectionCount: count
            )
        }

        let remoteDomains = hostConnCounts.map { ip, count in domain(endpoint: ip, count: count) }
        let loopbackDomains = loopbackConnCounts.map { port, count in
            domain(endpoint: Self.loopbackPrefix + String(port), count: count)
        }
        hostTotals[id] = appHostTotals
        // Several IPs of one service often reverse-resolve to the same name;
        // they are one row, and two rows would share an id in the lists.
        // Totals come from every endpoint under that name, including ones
        // with no connection open this tick, so a row's total never dips.
        var byHost: [String: DomainUsage] = [:]
        for d in remoteDomains + loopbackDomains {
            guard var merged = byHost[d.host] else { byHost[d.host] = d; continue }
            merged.rateDownKBps += d.rateDownKBps
            merged.connectionCount += d.connectionCount
            byHost[d.host] = merged
        }
        var totalsByHost: [String: HostTotals] = [:]
        for (endpoint, totals) in appHostTotals {
            let host = describe(endpoint: endpoint).host
            guard byHost[host] != nil else { continue }
            totalsByHost[host, default: HostTotals()].downKB += totals.downKB
            totalsByHost[host, default: HostTotals()].upKB += totals.upKB
        }
        for (host, totals) in totalsByHost {
            byHost[host]?.totalDownKB = totals.downKB
            byHost[host]?.totalUpKB = totals.upKB
        }
        usage.domains = byHost.values.sorted { $0.connectionCount > $1.connectionCount }

        refreshTotals(&usage)
        return usage
    }

    private func newUsage(id: String, name: String, bundleID: String, statusHint: String) -> AppUsage {
        var usage = AppUsage(
            id: id, name: name, bundleID: bundleID,
            badge: AppPalette.badge(bundleID: bundleID, name: name),
            connectionCount: 0, statusLine: statusHint,
            rateDownKBps: 0, rateUpKBps: 0,
            totalDownKB: [:], totalUpKB: [:],
            downHistory: [], upHistory: [], domains: [], isPaused: false
        )
        refreshTotals(&usage)
        return usage
    }

    private func refreshTotals(_ usage: inout AppUsage) {
        for r in TimeRange.allCases {
            let rolled = history.rollup(appID: usage.id, range: r)
            usage.totalDownKB[r] = rolled.downKB
            usage.totalUpKB[r] = rolled.upKB
        }
    }

    private static let loopbackPrefix = "localhost:"

    /// Display name and kind for an endpoint key from `hostTotals`.
    private func describe(endpoint: String) -> (host: String, kind: String) {
        if endpoint.hasPrefix(Self.loopbackPrefix),
           let port = Int(endpoint.dropFirst(Self.loopbackPrefix.count)) {
            // A machine running a local proxy sends most of a browser's
            // sockets to 127.0.0.1, where the destination is known only to
            // the proxy. Naming the process on the other end at least says
            // which one is carrying it.
            return (endpoint, loopbackPeerLabel(port: port))
        }
        let host = resolvedHosts[endpoint] ?? endpoint
        return (host, host == endpoint ? "IP 地址" : "已解析主机")
    }

    private func loopbackPeerLabel(port: Int) -> String {
        guard let listener = latestListeners[port] else { return "本机进程" }
        return "本机 · \(identify(pid: listener.pid, command: listener.command).name)"
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
