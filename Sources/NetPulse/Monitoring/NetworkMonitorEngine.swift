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
    @Published var section: SidebarSection = .apps
    /// 深度模式: relay the proxied traffic so destinations are measured
    /// rather than estimated. Off by default — it puts NetPulse in the data
    /// path (see ProxyRelay).
    @Published private(set) var deepModeEnabled = false
    @Published private(set) var deepModeHint: String = ""
    let relayPort: UInt16 = 1083
    @Published var popoverOpen: Bool = true
    @Published var searchText: String = ""
    @Published private(set) var status: MonitoringStatus = .starting

    private let nettop = NettopSampler()
    private let connections = ConnectionSampler()
    private let relay = ProxyRelay()
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
    /// Exact per-host totals measured by the relay, appID -> host. Present
    /// only for apps whose traffic went through it while 深度模式 was on.
    private var proxyHosts: [String: [String: HostTotals]] = [:]

    private struct HostTotals {
        var downKB: Double = 0
        var upKB: Double = 0
        var rateDownKBps: Double = 0
        var rateUpKBps: Double = 0
        var connections: Int = 0
    }
    /// Resolved hostnames for remote IPs seen so far.
    private var resolvedHosts: [String: String] = [:]

    private var tickTimer: Timer?
    private var hasStarted = false
    /// NetPulse's own row is skipped. In 深度模式 most of its bytes are other
    /// apps' traffic passing through the relay, so counting them here would
    /// report every proxied app twice.
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let ownBundleID = Bundle.main.bundleIdentifier

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
        setDeepMode(false)
        history.saveIfDirty()
    }

    // MARK: - 深度模式

    /// Starts the relay and tells the user where to point the system proxy.
    /// The upstream is read *before* the switch, so it is the user's real
    /// proxy rather than this relay — pointing the relay at itself would
    /// loop, and the guard below refuses that case outright.
    func setDeepMode(_ enabled: Bool) {
        guard enabled != deepModeEnabled else { return }
        guard enabled else {
            relay.stop()
            deepModeEnabled = false
            deepModeHint = ""
            return
        }
        guard let upstream = SystemProxy.current() else {
            deepModeHint = "未检测到系统 HTTP 代理，深度模式无处转发。"
            return
        }
        guard upstream.port != relayPort else {
            deepModeHint = "系统代理已指向 \(relayPort)，请先改回你的代理端口再开启。"
            return
        }
        relay.onFlowUpdate = { [weak self] deltas in
            Task { @MainActor in self?.ingestProxyFlows(deltas) }
        }
        relay.onStatusChange = { [weak self] newStatus in
            Task { @MainActor in
                if case .unavailable(let message) = newStatus {
                    self?.deepModeHint = message
                    self?.setDeepMode(false)
                }
            }
        }
        relay.start(config: ProxyRelay.Config(listenPort: relayPort,
                                              upstreamHost: upstream.host,
                                              upstreamPort: upstream.port))
        deepModeEnabled = true
        deepModeHint = "把系统代理改为 127.0.0.1:\(relayPort)（上游 \(upstream.description)）"
    }

    private func ingestProxyFlows(_ deltas: [ProxyFlowDelta]) {
        for delta in deltas {
            let identity = appIdentity[delta.pid] ?? {
                let resolved = ProcessDirectory.identify(pid: delta.pid, fallbackCommand: "pid-\(delta.pid)")
                appIdentity[delta.pid] = resolved
                return resolved
            }()
            var hosts = proxyHosts[identity.id] ?? [:]
            var totals = hosts[delta.host] ?? HostTotals()
            totals.downKB += delta.downKB
            totals.upKB += delta.upKB
            // One flush per second, so a KB in this batch is also KB/s.
            totals.rateDownKBps = delta.downKB
            totals.rateUpKBps = delta.upKB
            totals.connections += delta.newConnections
            hosts[delta.host] = totals
            proxyHosts[identity.id] = hosts
        }
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
    var domainRollups: [DomainRollup] {
        var byHost: [String: DomainRollup] = [:]
        for app in apps {
            for domain in app.domains {
                if var rollup = byHost[domain.host] {
                    rollup.rateDownKBps += domain.rateDownKBps
                    rollup.totalDownKB += domain.totalDownKB
                    rollup.totalUpKB += domain.totalUpKB
                    rollup.connectionCount += domain.connectionCount
                    if !rollup.appNames.contains(app.name) { rollup.appNames.append(app.name) }
                    byHost[domain.host] = rollup
                } else {
                    byHost[domain.host] = DomainRollup(host: domain.host,
                                                       kind: domain.kind,
                                                       rateDownKBps: domain.rateDownKBps,
                                                       totalDownKB: domain.totalDownKB,
                                                       totalUpKB: domain.totalUpKB,
                                                       connectionCount: domain.connectionCount,
                                                       appNames: [app.name])
                }
            }
        }
        return byHost.values.sorted { ($0.totalDownKB, $0.rateDownKBps) > ($1.totalDownKB, $1.rateDownKBps) }
    }

    var totalDownKBps: Double { apps.reduce(0) { $0 + $1.rateDownKBps } }
    var totalUpKBps: Double { apps.reduce(0) { $0 + $1.rateUpKBps } }
    var totalDownPct: Double { min(1, totalDownKBps / 12_000) }
    var totalUpPct: Double { min(1, totalUpKBps / 8_000) }
    var connectionCount: Int { apps.reduce(0) { $0 + $1.connectionCount } }

    // MARK: - Sampling

    private func ingestConnections(_ snapshot: ConnectionSnapshot) {
        let infos = snapshot.connections
        for info in infos { latestConnections[info.pid] = info }
        latestListeners = snapshot.listeners
        // Loopback peers are deliberately not resolved: reverse DNS answers
        // "localhost" for all of them, which is exactly the useless label the
        // listener lookup exists to replace.
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
            guard pid != ownPID else { continue }
            let identity = appIdentity[pid] ?? {
                let resolved = ProcessDirectory.identify(pid: pid, fallbackCommand: sample.command)
                appIdentity[pid] = resolved
                return resolved
            }()
            guard !pausedIDs.contains(identity.id) else { continue }
            if let ownBundleID, identity.bundleID == ownBundleID { continue }

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
        let previousDomains = usage.domains

        func domain(host: String, kind: String, count: Int) -> DomainUsage {
            let share = Double(count) / Double(totalConns)
            let existing = previousDomains.first(where: { $0.host == host })
            return DomainUsage(
                host: host,
                kind: kind,
                rateDownKBps: agg.downKBps * share,
                totalDownKB: (existing?.totalDownKB ?? 0) + agg.downKBps * share,
                totalUpKB: (existing?.totalUpKB ?? 0) + agg.upKBps * share,
                connectionCount: count
            )
        }

        let remoteDomains = hostConnCounts.map { ip, count -> DomainUsage in
            let host = resolvedHosts[ip] ?? ip
            return domain(host: host, kind: host == ip ? "IP 地址" : "已解析主机", count: count)
        }
        // 深度模式 measured this app's proxied traffic outright, so those rows
        // replace the loopback ones — they are the same bytes, counted rather
        // than split across sockets by connection count.
        let measuredDomains = (proxyHosts[id] ?? [:]).map { host, totals -> DomainUsage in
            DomainUsage(host: host,
                        kind: "代理 · 精确",
                        rateDownKBps: totals.rateDownKBps,
                        totalDownKB: totals.downKB,
                        totalUpKB: totals.upKB,
                        connectionCount: totals.connections)
        }
        // Without it, a machine running a local proxy sends most of a
        // browser's sockets to 127.0.0.1, where the destination is known only
        // to the proxy. Naming the process on the other end at least says
        // which one is carrying them.
        let loopbackDomains = measuredDomains.isEmpty
            ? loopbackConnCounts.map { port, count -> DomainUsage in
                domain(host: "localhost:\(port)", kind: loopbackPeerLabel(port: port), count: count)
            }
            : []
        usage.domains = (remoteDomains + measuredDomains + loopbackDomains)
            .sorted { $0.connectionCount > $1.connectionCount }

        for r in TimeRange.allCases {
            let rolled = history.rollup(appID: id, range: r)
            usage.totalDownKB[r] = rolled.downKB
            usage.totalUpKB[r] = rolled.upKB
        }
        return usage
    }

    private func loopbackPeerLabel(port: Int) -> String {
        guard let listener = latestListeners[port] else { return "本机进程" }
        let name = ProcessDirectory.identify(pid: listener.pid, fallbackCommand: listener.command).name
        return "本机 · \(name)"
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
