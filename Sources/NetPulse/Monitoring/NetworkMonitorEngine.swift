import AppKit

private let pausedAppsDefaultsKey = "pausedAppIDs"
private let showIdleAppsDefaultsKey = "showIdleApps"

/// Orchestrates the live monitors into the `apps`/`selectedApp`/etc. state
/// the UI binds to — the real-data analogue of `renderVals()` in the
/// original design's mock, but driven by actual `nettop`/`lsof` sampling
/// instead of `Math.random()`.
@MainActor
final class NetworkMonitorEngine: ObservableObject {
    @Published private(set) var apps: [AppUsage] = []
    @Published var selectedAppID: String?
    @Published var sortMode: SortMode = .rate { didSet { resort() } }
    @Published var rateWindow: RateWindow = .live { didSet { resort() } }
    @Published var range: TimeRange = .today {
        didSet {
            refreshDomainTotals()
            resort()
        }
    }
    @Published var section: SidebarSection = .apps
    @Published var popoverOpen: Bool = true
    @Published var searchText: String = ""
    /// Processes that hold a socket but have never moved a byte (mostly
    /// system daemons) crowd the list; they are hidden unless asked for.
    @Published var showIdleApps: Bool = false {
        didSet { defaults.set(showIdleApps, forKey: showIdleAppsDefaultsKey) }
    }
    @Published private(set) var status: MonitoringStatus = .starting
    /// Machine-wide rates over the last 60 ticks, oldest first — what the
    /// menu bar chip draws and what the sidebar meters are scaled against.
    @Published private(set) var totalDownHistory: [Double] = []
    @Published private(set) var totalUpHistory: [Double] = []
    /// Apps with saved totals that haven't run this launch. Listed only
    /// under 累计流量, where 本周/本月 would otherwise leave out everything
    /// that was quit before NetPulse started.
    @Published private(set) var archivedApps: [AppUsage] = []
    /// Sites from the local proxy's log, by UA product (see ProxyLogReader).
    @Published private(set) var proxyVisitsByProduct: [String: [String: ProxyVisit]] = [:]

    private let nettop: NettopSource
    private let connections: ConnectionSampler
    private let dns = ReverseDNSResolver()
    private let proxyLog: ProxyLogReader
    private let hostCapture = ProxyHostCapture()
    /// Whether the loopback capture daemon is installed (see ProxyHostCapture).
    @Published private(set) var proxyHostCaptureInstalled = ProxyHostCapture.isInstalled
    /// Installed, but by an older build whose daemon differs.
    @Published private(set) var proxyHostCaptureOutdated = false
    /// Source port of an app's connection to a local proxy → the site it
    /// asked for, from `hostCapture`, and when that was seen.
    private var proxyHosts: [Int: (host: String, seen: Date)] = [:]
    private let proxyLogQueue = DispatchQueue(label: "NetPulse.proxyLog", qos: .utility)
    private var proxyLogReadInFlight = false
    private let history: HistoryStore

    /// Per-pid cumulative counters from the previous tick, to derive deltas.
    private var previousSamples: [Int32: NettopSampler.Sample] = [:]
    /// pid -> stable app identity, resolved once per pid.
    private var appIdentity: [Int32: ProcessDirectory.Identity] = [:]
    /// Latest per-pid connection info, refreshed every few seconds.
    private var latestConnections: [Int32: ConnectionInfo] = [:]
    /// Who is listening on which port, so a loopback peer can be named.
    private var latestListeners: [Int: ListenerInfo] = [:]
    /// Client end of each loopback connection, by its ephemeral port.
    private var latestLoopbackClients: [Int: ListenerInfo] = [:]
    /// The same from nettop's connections, which, unlike lsof run as the
    /// user, also lists root daemons' sockets: without it a loopback peer
    /// that is a root process could only be called "本机进程".
    private var nettopLoopbackPorts: [Int: ListenerInfo] = [:]
    /// Names for "forward:<app id>" endpoints, kept after the app's
    /// connections close so their totals keep their label.
    private var forwardedAppNames: [String: String] = [:]
    /// Apps other apps reach through a loopback listener; set each tick.
    private var proxyAppIDs: Set<String> = []
    /// VPN packet tunnels seen this launch. Like a local proxy, a tunnel
    /// carries other apps' bytes a second time, so it is left out of totals.
    private var tunnelAppIDs: Set<String> = []
    /// Resolved hostnames for remote IPs seen so far.
    private var resolvedHosts: [String: String] = [:]
    /// IPs with a reverse lookup already under way, so an lsof pass that
    /// lands before the answer doesn't start a second one.
    private var pendingLookups: Set<String> = []
    // Per-host bytes live in `history`, by day, so a host's total survives
    // its connections closing and NetPulse relaunching, and follows `range`
    // like the app totals do. They are recorded under the raw endpoint — the
    // remote IP, or `localhost:<port>` — so a later reverse-DNS answer
    // relabels the row instead of starting a second one under the new name.
    /// The last per-connection sample, and what it measured per app and
    /// endpoint since the one before (see `ingestFlows`).
    private var previousFlows: [Int32: NettopSampler.Sample] = [:]
    private var previousFlowsAt: Date?
    private var flowRates: [String: [String: HostTotals]] = [:]
    private var flowConns: [String: [String: Int]] = [:]
    /// Set once nettop has reported connections; from then on hosts are
    /// measured rather than estimated.
    private var hasFlowData = false
    /// Apps the user excluded from counting. Persisted, so a pause outlives
    /// the app relaunching (or NetPulse restarting).
    private var pausedIDs: Set<String>
    private let defaults: UserDefaults
    private var tickCount = 0

    private var tickTimer: Timer?
    private var hasStarted = false
    /// Set by the main window once it appears; the UI self-test opens the
    /// main window through it exactly as the popover button does.
    var openMainWindowAction: (@MainActor () -> Void)?
    private let identifyProcess: (Int32, String) -> ProcessDirectory.Identity

    /// Parameters exist for tests, which drive `tick()` and
    /// `ingestConnections(_:)` directly with canned data.
    init(nettop: NettopSource = NettopSampler(),
         connections: ConnectionSampler = ConnectionSampler(),
         history: HistoryStore = HistoryStore(),
         defaults: UserDefaults = .standard,
         proxyLog: ProxyLogReader = ProxyLogReader(),
         identify: @escaping (Int32, String) -> ProcessDirectory.Identity = ProcessDirectory.identify) {
        self.identifyProcess = identify
        self.proxyLog = proxyLog
        self.nettop = nettop
        self.connections = connections
        self.history = history
        self.defaults = defaults
        pausedIDs = Set(defaults.stringArray(forKey: pausedAppsDefaultsKey) ?? [])
        showIdleApps = defaults.bool(forKey: showIdleAppsDefaultsKey)
    }

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
        hostCapture.onHosts = { [weak self] hosts in self?.ingestProxyHosts(hosts) }
        hostCapture.start()
        proxyHostCaptureOutdated = proxyHostCaptureInstalled && !hostCapture.isCurrent
        connections.start()
        scheduleSelfTestIfRequested()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Timer's block is `@Sendable`, so the `weak self` capture reads as a
            // mutable var there — binding it to an immutable `self` first is what
            // lets the inner `Task` capture it.
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    /// `NETPULSE_SELFTEST_SECONDS=N` makes the app print `selfTestReport()`
    /// to stdout after N seconds and quit — how CI checks the real
    /// nettop/lsof pipeline on a real Mac, where nobody can look at the UI.
    private func scheduleSelfTestIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["NETPULSE_SELFTEST_SECONDS"],
              let seconds = Double(raw), seconds > 0 else { return }
        let snapshotDir = ProcessInfo.processInfo.environment["NETPULSE_SELFTEST_SNAPSHOTS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        Task { @MainActor in
            var ui: [String: Any]?
            if let snapshotDir {
                ui = await UISelfTest.run(engine: self, seconds: seconds, outputDir: snapshotDir)
            } else {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            FileHandle.standardOutput.write(self.selfTestReport(ui: ui))
            FileHandle.standardOutput.write(Data("\n".utf8))
            self.stop()
            exit(0)
        }
    }

    /// What the engine is showing right now, as JSON.
    func selfTestReport(ui: [String: Any]? = nil) -> Data {
        let statusText: String
        switch status {
        case .starting: statusText = "starting"
        case .ok: statusText = "ok"
        case .degraded(let message): statusText = "degraded: \(message)"
        case .unavailable(let message): statusText = "unavailable: \(message)"
        }
        let appRows: [[String: Any]] = apps.map { app in
            [
                "id": app.id,
                "name": app.name,
                "status": app.statusLine,
                "rateDownKBps": app.rateDownKBps,
                "rateUpKBps": app.rateUpKBps,
                "todayDownKB": app.totalDownKB[.today] ?? 0,
                "todayUpKB": app.totalUpKB[.today] ?? 0,
                "connections": app.connectionCount,
                // Hosts in use now; ones that only keep this launch's
                // totals don't count.
                "hosts": app.domains.filter { $0.connectionCount > 0 || $0.rateDownKBps > 0 }.map(\.host),
            ]
        }
        var report: [String: Any] = [
            "status": statusText,
            "totalDownKBps": totalDownKBps,
            "totalUpKBps": totalUpKBps,
            "apps": appRows,
            "domainRollups": domainRollups.map(\.host),
            "archivedApps": archivedApps.map(\.id),
        ]
        if let ui { report["ui"] = ui }
        return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        nettop.stop()
        connections.stop()
        hostCapture.stop()
        history.saveIfDirty()
    }

    func select(appID: String) {
        selectedAppID = appID
        userPickedSelection = true
    }
    /// Until someone picks a row, an idle selection moves to the busiest
    /// app: the first ticks after launch have no rates yet to choose by.
    private var userPickedSelection = false
    func togglePopover() { popoverOpen.toggle() }
    func openMainWindow() { popoverOpen = false }

    func togglePause(appID: String) {
        if pausedIDs.contains(appID) { pausedIDs.remove(appID) } else { pausedIDs.insert(appID) }
        defaults.set(Array(pausedIDs), forKey: pausedAppsDefaultsKey)
        if let idx = apps.firstIndex(where: { $0.id == appID }) {
            apps[idx].isPaused = pausedIDs.contains(appID)
        }
        if let idx = archivedApps.firstIndex(where: { $0.id == appID }) {
            archivedApps[idx].isPaused = pausedIDs.contains(appID)
        }
    }

    // MARK: - Derived state consumed by views

    /// What the app list shows: the live apps, plus under 累计流量 the
    /// archived ones that have traffic in the selected range.
    var listedApps: [AppUsage] {
        let shown = showIdleApps ? apps : apps.filter { !isIdle($0) || $0.id == selectedAppID }
        guard sortMode == .total else { return shown }
        let liveIDs = Set(apps.map(\.id))
        let archived = archivedApps.filter {
            !liveIDs.contains($0.id) && ($0.totalDownKB[range] ?? 0) + ($0.totalUpKB[range] ?? 0) > 0
        }
        return (shown + archived).sorted(by: comparator(for: sortMode, range: range))
    }

    /// How many rows `listedApps` leaves out as idle.
    var hiddenIdleCount: Int {
        showIdleApps ? 0 : apps.filter { isIdle($0) && $0.id != selectedAppID }.count
    }

    /// Below this over the rate window, an app is idle under 实时速率.
    static let idleRateKBps = 1.0

    /// Under 实时速率: under 1 KB/s over the window, so the list holds only
    /// what is using the network. Under 累计流量: never moved a byte, in
    /// this launch or any saved day. A paused app stays listed either way:
    /// its row is where it gets resumed.
    func isIdle(_ app: AppUsage) -> Bool {
        guard !app.isPaused else { return false }
        if sortMode == .rate {
            return app.windowDownKBps + app.windowUpKBps < Self.idleRateKBps
                && app.rateDownKBps + app.rateUpKBps < Self.idleRateKBps
        }
        return app.rateDownKBps + app.rateUpKBps == 0
            && (app.totalDownKB[.all] ?? 0) + (app.totalUpKB[.all] ?? 0) == 0
    }

    /// Top of scale for the list's trend lines: the busiest of them, so a
    /// trickle no longer draws as tall as a download.
    var trendScaleMax: Double {
        var peak: Double = 1
        for app in listedApps {
            peak = max(peak, app.downHistory.suffix(24).max() ?? 0, app.upHistory.suffix(24).max() ?? 0)
        }
        return peak
    }

    /// The `count` apps that moved the most over `window`, with their
    /// average rates; for the popover, independent of the list's window.
    func topApps(over window: RateWindow, count: Int) -> [(app: AppUsage, downKBps: Double, upKBps: Double)] {
        let span = max(1, min(window.seconds, tickCount))
        var entries: [(app: AppUsage, downKBps: Double, upKBps: Double)] = []
        for app in countedApps {
            let down: Double = app.downHistory.suffix(span).reduce(0, +) / Double(span)
            let up: Double = app.upHistory.suffix(span).reduce(0, +) / Double(span)
            if down + up >= Self.idleRateKBps { entries.append((app, down, up)) }
        }
        entries.sort { $0.downKBps + $0.upKBps > $1.downKBps + $1.upKBps }
        return Array(entries.prefix(count))
    }

    /// One layer of the stacked traffic chart.
    struct StackLayer: Identifiable {
        var id: String
        var name: String
        /// Down + up KB/s per time bucket, oldest first.
        var values: [Double]
    }

    /// The machine's traffic over `rateWindow`, split into the top apps
    /// plus 其他, averaged into at most `buckets` points. A proxy is left
    /// out: its bytes are the other apps' again.
    func stackLayers(top: Int = 5, buckets: Int = 90) -> [StackLayer] {
        let span = max(2, min(rateWindow.seconds, tickCount))
        let perBucket = max(1, Int((Double(span) / Double(buckets)).rounded(.up)))
        func bucketed(_ app: AppUsage) -> [Double] {
            let down = Array(app.downHistory.suffix(span)), up = Array(app.upHistory.suffix(span))
            // Apps seen for less than the window are padded with leading zeros.
            var series = [Double](repeating: 0, count: span - down.count)
            for i in down.indices {
                let upValue: Double = i < up.count ? up[i] : 0
                series.append(down[i] + upValue)
            }
            var points: [Double] = []
            var start = 0
            while start < series.count {
                let end = min(start + perBucket, series.count)
                let sum: Double = series[start..<end].reduce(0, +)
                points.append(sum / Double(end - start))
                start = end
            }
            return points
        }
        var ranked: [(app: AppUsage, series: [Double], total: Double)] = []
        for app in countedApps {
            let series = bucketed(app)
            let total: Double = series.reduce(0, +)
            if total > 0 { ranked.append((app, series, total)) }
        }
        ranked.sort { $0.total > $1.total }
        var layers = ranked.prefix(top).map { StackLayer(id: $0.app.id, name: $0.app.name, values: $0.series) }
        let rest = ranked.dropFirst(top)
        if let first = rest.first {
            var other = first.series
            for entry in rest.dropFirst() {
                for i in other.indices where i < entry.series.count { other[i] += entry.series[i] }
            }
            layers.append(StackLayer(id: "__other", name: "其他", values: other))
        }
        return layers
    }

    var filteredApps: [AppUsage] {
        guard !searchText.isEmpty else { return listedApps }
        return listedApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// The detail pane's host order: it follows the list's 实时速率 /
    /// 累计流量 toggle, which the section header already claimed it did.
    func sortedDomains(of app: AppUsage) -> [DomainUsage] {
        switch sortMode {
        case .rate:
            return app.domains.sorted {
                ($0.rateDownKBps, $0.connectionCount, $0.totalDownKB) > ($1.rateDownKBps, $1.connectionCount, $1.totalDownKB)
            }
        case .total:
            return app.domains.sorted { ($0.totalDownKB, $0.totalUpKB) > ($1.totalDownKB, $1.totalUpKB) }
        }
    }

    var selectedApp: AppUsage? {
        apps.first(where: { $0.id == selectedAppID })
            ?? archivedApps.first(where: { $0.id == selectedAppID })
            ?? apps.first
    }

    /// Apps whose traffic is their own, not forwarded for another app.
    private var countedApps: [AppUsage] { apps.filter { !$0.isProxy } }

    /// The popover's busiest apps, by the same 近 10 秒 average the main
    /// list ranks by (an instant value put a different app first), idle
    /// apps left out.
    var popoverTop: [(app: AppUsage, downKBps: Double, upKBps: Double)] {
        topApps(over: .live, count: 5)
    }

    var topApp: AppUsage? { popoverTop.first?.app }

    /// The whole Mac's 近 10 秒 average, for the popover's footer: beside
    /// rows averaged over 10 s, an instant total could read lower than one
    /// of its own apps.
    var recentTotalKBps: (down: Double, up: Double) {
        func average(_ history: [Double]) -> Double {
            let recent = history.suffix(RateWindow.live.seconds)
            return recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
        }
        return (average(totalDownHistory), average(totalUpHistory))
    }

    /// 活跃连接: every app's hosts flattened into one machine-wide list,
    /// busiest first.
    var connectionRows: [ConnectionRow] {
        apps.flatMap { app in
            app.domains.filter { $0.connectionCount > 0 || $0.rateDownKBps > 0 }.map { domain in
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
        let names = Dictionary((archivedApps + apps).map { ($0.id, $0.name) }, uniquingKeysWith: { _, live in live })
        for (appID, hosts) in history.hostTotalsByApp(range: range) {
            guard let appName = names[appID] ?? history.name(for: appID) else { continue }
            // A proxy's "为 X 转发" rows are apps, not domains.
            for (host, totals) in hosts where !Self.nonDomainKinds.contains(totals.kind) {
                let kind = totals.kind
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

    // A proxy's bytes are the apps' bytes again, on their way out.
    var totalDownKBps: Double { countedApps.reduce(0) { $0 + $1.rateDownKBps } }
    var totalUpKBps: Double { countedApps.reduce(0) { $0 + $1.rateUpKBps } }
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

    func ingestConnections(_ snapshot: ConnectionSnapshot) {
        let infos = snapshot.connections
        // Replaced wholesale, not merged: lsof leaves out a process that has
        // closed its last socket, and merging kept that process's old hosts
        // on screen indefinitely.
        latestConnections = Dictionary(infos.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        latestListeners = snapshot.listeners
        latestLoopbackClients = snapshot.loopbackClients
        if let flows = snapshot.flows { ingestFlows(flows, at: snapshot.takenAt) }
        // Loopback peers are deliberately not resolved: reverse DNS answers
        // "localhost" for all of them, which is exactly the useless label the
        // listener lookup exists to replace.
        resolveHosts(Set(infos.flatMap { Array($0.remoteCounts.keys) }))
    }

    private func resolveHosts(_ seenIPs: Set<String>) {
        let unresolved = seenIPs.subtracting(resolvedHosts.keys).subtracting(pendingLookups)
        guard !unresolved.isEmpty else { return }
        pendingLookups.formUnion(unresolved)
        Task {
            for ip in unresolved {
                let host = await dns.resolve(ip)
                await MainActor.run {
                    self.resolvedHosts[ip] = host
                    self.pendingLookups.remove(ip)
                    self.history.relabelHosts { $0 == ip ? self.describe(endpoint: ip) : nil }
                }
            }
        }
    }

    func tick() {
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
            if identity.isTunnel { tunnelAppIDs.insert(identity.id) }
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
            if downDeltaKB > 0 || upDeltaKB > 0 {
                history.rememberName(identity.name, for: identity.id)
            }
        }
        previousSamples = samples

        proxyAppIDs = findProxyApps()
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

        // Ranks, share bars and rate columns all come from the same numbers,
        // refreshed together every few seconds: refreshed separately, a row
        // at 68% could sit below one at 15% until the next re-rank.
        if listOrder.isEmpty || tickCount % Self.reorderInterval == 0 {
            apps = ordered(withWindowRates(Array(next.values)))
        } else {
            let previous = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            apps = ordered(next.values.map { app in
                guard let old = previous[app.id] else { return app }
                var app = app
                app.windowDownKBps = old.windowDownKBps
                app.windowUpKBps = old.windowUpKBps
                app.windowShare = old.windowShare
                return app
            })
        }
        totalDownHistory = Array((totalDownHistory + [totalDownKBps]).suffix(60))
        totalUpHistory = Array((totalUpHistory + [totalUpKBps]).suffix(60))
        if tickCount % 5 == 1 { refreshArchivedApps() }
        if tickCount % 5 == 2, !proxyAppIDs.isEmpty { refreshProxyLog() }
        let busiest = apps.max { $0.rateDownKBps + $0.rateUpKBps < $1.rateDownKBps + $1.rateUpKBps }
            .flatMap { $0.rateDownKBps + $0.rateUpKBps > 0 ? $0 : nil }
        if let sel = selectedAppID,
           next[sel] != nil || archivedApps.contains(where: { $0.id == sel }) {
            // Moves off an idle row only, so a busy selection doesn't hop
            // between apps every second.
            let selIdle = next[sel].map { $0.rateDownKBps + $0.rateUpKBps == 0 } ?? true
            if !userPickedSelection, selIdle, let busiest { selectedAppID = busiest.id }
        } else {
            // Open on what is moving right now, not on whichever idle row
            // the current sort puts first.
            selectedAppID = (busiest ?? apps.first)?.id
            userPickedSelection = false
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
        // The same word history rows use: whether it quit during this launch
        // or before it, the app isn't running now.
        usage.statusLine = paused ? "已暂停统计" : "未运行"
        usage.rateDownKBps = 0
        usage.rateUpKBps = 0
        usage.downHistory = Array((usage.downHistory + [0]).suffix(Self.historyLength))
        usage.upHistory = Array((usage.upHistory + [0]).suffix(Self.historyLength))
        // Its hosts stay with what they carried; nothing is open or moving
        // any more.
        usage.domains = domainRows(for: existing.id, live: [:])
        usage.connectionCount = 0
        return usage
    }

    /// Reads new proxy-log rows off the main thread; only while a local
    /// proxy is in use, since the log is only written then.
    private func refreshProxyLog() {
        guard !proxyLogReadInFlight else { return }
        proxyLogReadInFlight = true
        let reader = proxyLog
        proxyLogQueue.async {
            reader.refresh()
            let visits = reader.visitsByProduct
            DispatchQueue.main.async {
                self.proxyLogReadInFlight = false
                if self.proxyVisitsByProduct != visits { self.proxyVisitsByProduct = visits }
            }
        }
    }

    /// Sites `app` reached through the local proxy, most recent first. A
    /// proxy's own row gets the connections its log can't tie to an app.
    func proxyVisits(of app: AppUsage) -> [ProxyVisit] {
        // A VPN tunnel isn't the proxy whose log this is.
        if tunnelAppIDs.contains(app.id) { return [] }
        let products = app.isProxy
            ? [ProxyLogReader.unattributed]
            : ProxyLogReader.products(forAppID: app.id, name: app.name, in: proxyVisitsByProduct.keys)
        var merged: [String: ProxyVisit] = [:]
        for product in products {
            for (host, visit) in proxyVisitsByProduct[product] ?? [:] {
                guard var existing = merged[host] else { merged[host] = visit; continue }
                existing.count += visit.count
                if visit.lastSeen > existing.lastSeen {
                    existing.lastSeen = visit.lastSeen
                    existing.policy = visit.policy
                    existing.rule = visit.rule
                }
                merged[host] = existing
            }
        }
        return merged.values.sorted { ($0.lastSeen, $0.count) > ($1.lastSeen, $1.count) }
    }

    /// Rebuilds `archivedApps` from saved history. Every five ticks is
    /// plenty: these rows' totals only change when a day rolls over.
    private func refreshArchivedApps() {
        let liveIDs = Set(apps.map(\.id))
        var perRange: [TimeRange: [String: (downKB: Double, upKB: Double)]] = [:]
        for r in TimeRange.allCases { perRange[r] = history.totalsByApp(range: r) }
        let allTime = perRange[.all] ?? [:]
        archivedApps = allTime.keys.filter { !liveIDs.contains($0) }.compactMap { id in
            guard let t = allTime[id], t.downKB + t.upKB > 0 else { return nil }
            let name = history.name(for: id) ?? Self.fallbackName(for: id)
            var usage = AppUsage(
                id: id, name: name, bundleID: id,
                badge: AppPalette.badge(bundleID: id, name: name),
                connectionCount: 0, statusLine: "未运行",
                rateDownKBps: 0, rateUpKBps: 0,
                totalDownKB: [:], totalUpKB: [:],
                downHistory: [], upHistory: [], domains: domainRows(for: id, live: [:]),
                isPaused: pausedIDs.contains(id), isLive: false
            )
            for r in TimeRange.allCases {
                usage.totalDownKB[r] = perRange[r]?[id]?.downKB ?? 0
                usage.totalUpKB[r] = perRange[r]?[id]?.upKB ?? 0
            }
            return usage
        }
    }

    /// A name for history recorded before names were saved: the installed
    /// app's name for a bundle ID, or the process name behind `proc.`.
    private static func fallbackName(for id: String) -> String {
        if id.hasPrefix("proc.") { return String(id.dropFirst("proc.".count)) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return id
    }

    private func identify(pid: Int32, command: String) -> ProcessDirectory.Identity {
        if let known = appIdentity[pid] { return known }
        let resolved = identifyProcess(pid, command)
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

    func ingestProxyHosts(_ hosts: [Int: String], at date: Date = Date()) {
        for (port, host) in hosts { proxyHosts[port] = (host, date) }
    }

    /// Asks for an administrator password and installs the capture daemon.
    /// Returns an error message, or nil on success.
    func installProxyHostCapture() -> String? {
        let error = hostCapture.install()
        proxyHostCaptureInstalled = ProxyHostCapture.isInstalled
        proxyHostCaptureOutdated = proxyHostCaptureInstalled && !hostCapture.isCurrent
        return error
    }

    func removeProxyHostCapture() -> String? {
        let error = hostCapture.uninstall()
        proxyHostCaptureInstalled = ProxyHostCapture.isInstalled
        proxyHostCaptureOutdated = proxyHostCaptureInstalled && !hostCapture.isCurrent
        return error
    }

    private struct AppFlows {
        var kb: [String: HostTotals] = [:]
        var conns: [String: Int] = [:]
    }

    /// Takes one sample of nettop's per-connection counters: each app's
    /// bytes since the previous sample go into its hosts' totals, and the
    /// rate and open connections per host are kept for the rows until the
    /// next sample.
    func ingestFlows(_ newFlows: [Int32: NettopSampler.Sample], at date: Date) {
        let elapsed = previousFlowsAt.map { max(0.5, date.timeIntervalSince($0)) }
        // Counters only grow while a connection lives, but a sample can show
        // one lower — a row printed without its counters reads as zero — and
        // the next sample's full value would then be counted a second time.
        // So each counter is held at the highest value seen.
        var flows = newFlows
        var loopbackPorts: [Int: ListenerInfo] = [:]
        for (pid, sample) in newFlows {
            for conn in sample.connections.values where conn.isLoopback {
                if let port = conn.localPort, loopbackPorts[port] == nil {
                    loopbackPorts[port] = ListenerInfo(pid: pid, command: sample.command)
                }
            }
        }
        nettopLoopbackPorts = loopbackPorts
        for (pid, sample) in newFlows {
            guard let old = previousFlows[pid] else { continue }
            var held = NettopSampler.Sample(pid: pid, command: sample.command,
                                            bytesInCumKB: max(sample.bytesInCumKB, old.bytesInCumKB),
                                            bytesOutCumKB: max(sample.bytesOutCumKB, old.bytesOutCumKB))
            held.connections = sample.connections
            for (key, conn) in sample.connections {
                guard let prev = old.connections[key] else { continue }
                held.connections[key] = NettopSampler.Connection(
                    remoteHost: conn.remoteHost, remotePort: conn.remotePort,
                    bytesIn: max(conn.bytesIn, prev.bytesIn), bytesOut: max(conn.bytesOut, prev.bytesOut),
                    localPort: conn.localPort)
            }
            flows[pid] = held
        }
        var byApp: [String: AppFlows] = [:]
        var remoteIPs: Set<String> = []
        for (pid, sample) in flows {
            let identity = identify(pid: pid, command: sample.command)
            guard !pausedIDs.contains(identity.id) else { continue }
            var flow = byApp[identity.id] ?? AppFlows()
            // A process first seen after the first sample started since, or
            // opened its first socket since: its connections' counters all
            // grew since then (they start at zero). What its process counter
            // held before that can't be placed, so none of it goes to 已关闭.
            var previous = previousFlows[pid]
            if elapsed != nil, previous == nil {
                let connIn = sample.connections.values.reduce(0) { $0 + $1.bytesIn } / 1024
                let connOut = sample.connections.values.reduce(0) { $0 + $1.bytesOut } / 1024
                previous = NettopSampler.Sample(pid: pid, command: sample.command,
                                                bytesInCumKB: max(0, sample.bytesInCumKB - connIn),
                                                bytesOutCumKB: max(0, sample.bytesOutCumKB - connOut))
            }
            splitByConnection(sample, previous: elapsed == nil ? nil : previous,
                              appID: identity.id, into: &flow)
            byApp[identity.id] = flow
            for conn in sample.connections.values where conn.remoteHost != "*" && !conn.isLoopback {
                remoteIPs.insert(conn.remoteHost)
            }
        }
        var rates: [String: [String: HostTotals]] = [:]
        for (appID, flow) in byApp {
            var appRates: [String: HostTotals] = [:]
            for (endpoint, kb) in flow.kb {
                recordHost(appID: appID, endpoint: endpoint, kb)
                if let elapsed {
                    appRates[endpoint] = HostTotals(downKB: kb.downKB / elapsed, upKB: kb.upKB / elapsed)
                }
            }
            rates[appID] = appRates
        }
        flowRates = rates
        flowConns = byApp.mapValues(\.conns)
        previousFlows = flows
        previousFlowsAt = date
        // A port's site is kept while its connection lives; a capture that
        // lands before nettop first lists the connection gets a minute.
        var openPorts: Set<Int> = []
        for sample in flows.values {
            for conn in sample.connections.values { if let port = conn.localPort { openPorts.insert(port) } }
        }
        proxyHosts = proxyHosts.filter { openPorts.contains($0.key) || date.timeIntervalSince($0.value.seen) < 60 }
        if flows.values.contains(where: { !$0.connections.isEmpty }) { hasFlowData = true }
        if !remoteIPs.isEmpty { resolveHosts(remoteIPs) }
    }

    /// Endpoint for bytes whose connection closed between two samples: the
    /// process's counters include them, but no connection row is left to
    /// say where they went.
    private static let closedEndpoint = "closed:"
    /// Kinds of host rows that aren't a place on the network: forwarded
    /// apps, closed connections, unconnected sockets.
    private static let nonDomainKinds: Set<String> = ["代理转发", "连接已结束，无法再分到网站", "广播 / 本地发现"]
    /// Sockets with no fixed peer (mDNS, some UDP senders).
    private static let unconnectedEndpoint = "unconnected:"

    /// Adds one process's traffic since the previous sample to `flow`, per
    /// remote endpoint,
    /// from the growth of each connection's own counters. A connection that
    /// wasn't there last sample opened since, so all of its bytes are new;
    /// whatever the process moved beyond its open connections went through
    /// ones that have already closed.
    private func splitByConnection(_ sample: NettopSampler.Sample, previous: NettopSampler.Sample?,
                                   appID: String, into flow: inout AppFlows) {
        let downKB = max(0, sample.bytesInCumKB - (previous?.bytesInCumKB ?? sample.bytesInCumKB))
        let upKB = max(0, sample.bytesOutCumKB - (previous?.bytesOutCumKB ?? sample.bytesOutCumKB))
        var seenDown = 0.0
        var seenUp = 0.0
        for (key, conn) in sample.connections {
            let endpoint: String
            if conn.remoteHost == "*" {
                endpoint = Self.unconnectedEndpoint
            } else if conn.isLoopback, let port = conn.localPort, let site = proxyHosts[port] {
                // The site this connection asked the local proxy for.
                endpoint = Self.sitePrefix + site.host
            } else if conn.isLoopback {
                endpoint = loopbackEndpoint(port: conn.remotePort ?? 0, appID: appID)
            } else {
                endpoint = conn.remoteHost
            }
            if conn.remoteHost != "*" { flow.conns[endpoint, default: 0] += 1 }
            // A process's first sample is only the baseline, as for its totals.
            guard let previous else { continue }
            let old = previous.connections[key]
            let down = max(0, conn.bytesIn - (old?.bytesIn ?? 0)) / 1024
            let up = max(0, conn.bytesOut - (old?.bytesOut ?? 0)) / 1024
            guard down > 0 || up > 0 else { continue }
            flow.kb[endpoint, default: HostTotals()].downKB += down
            flow.kb[endpoint, default: HostTotals()].upKB += up
            seenDown += down
            seenUp += up
        }
        guard previous != nil else { return }
        let restDown = max(0, downKB - seenDown)
        let restUp = max(0, upKB - seenUp)
        guard restDown > 0 || restUp > 0 else { return }
        flow.kb[Self.closedEndpoint, default: HostTotals()].downKB += restDown
        flow.kb[Self.closedEndpoint, default: HostTotals()].upKB += restUp
    }

    private func buildUsage(id: String, agg: Aggregate) -> AppUsage {
        var usage = apps.first(where: { $0.id == id })
            ?? newUsage(id: id, name: agg.name, bundleID: agg.bundleID, statusHint: agg.statusHint)
        let isTunnel = tunnelAppIDs.contains(id)
        usage.isProxy = isTunnel || proxyAppIDs.contains(id)
        usage.statusLine = isTunnel ? "VPN 隧道 · 不计入合计"
            : usage.isProxy ? "本机代理 · 不计入合计" : agg.statusHint
        usage.isPaused = false
        usage.rateDownKBps = agg.downKBps
        usage.rateUpKBps = agg.upKBps
        usage.downHistory = Array((usage.downHistory + [agg.downKBps]).suffix(Self.historyLength))
        usage.upHistory = Array((usage.upHistory + [agg.upKBps]).suffix(Self.historyLength))

        // KB per second and open connections per endpoint: measured over the
        // last two connection samples when nettop gives them, otherwise the
        // app's rate split by how many of its lsof connections go to each
        // endpoint.
        var tickKB: [String: HostTotals] = [:]
        var connCounts: [String: Int] = [:]
        if hasFlowData {
            tickKB = flowRates[id] ?? [:]
            connCounts = flowConns[id] ?? [:]
        } else {
            for pid in agg.pids {
                guard let info = latestConnections[pid] else { continue }
                for (ip, count) in info.remoteCounts {
                    connCounts[ip, default: 0] += count
                }
                for (port, count) in info.loopbackCounts {
                    connCounts[loopbackEndpoint(port: port, appID: id), default: 0] += count
                }
            }
            let totalConns = Double(max(1, connCounts.values.reduce(0, +)))
            for (endpoint, count) in connCounts {
                let share = Double(count) / totalConns
                tickKB[endpoint] = HostTotals(downKB: agg.downKBps * share, upKB: agg.upKBps * share)
            }
            // One-second tick, so the rate is also this tick's KB.
            for (endpoint, kb) in tickKB {
                recordHost(appID: id, endpoint: endpoint, kb)
            }
        }
        usage.connectionCount = connCounts.values.reduce(0, +)

        // Several IPs of one service often reverse-resolve to the same name;
        // they are one row, and two rows would share an id in the lists.
        var live: [String: DomainUsage] = [:]
        for endpoint in Set(connCounts.keys).union(tickKB.keys) {
            let (host, kind) = describe(endpoint: endpoint)
            var row = live[host] ?? DomainUsage(host: host, kind: kind, rateDownKBps: 0,
                                                totalDownKB: 0, totalUpKB: 0, connectionCount: 0)
            row.rateDownKBps += tickKB[endpoint]?.downKB ?? 0
            row.connectionCount += connCounts[endpoint] ?? 0
            live[host] = row
        }
        usage.domains = domainRows(for: id, live: live)

        refreshTotals(&usage)
        return usage
    }

    /// An app's host rows: the hosts open or moving now (`live`, by name),
    /// and every one that carried traffic in the selected range — a
    /// download's host staying listed after its connection closes is the
    /// point of the breakdown. Totals follow `range`, like the tiles above
    /// them, earlier launches included.
    private func domainRows(for id: String, live: [String: DomainUsage]) -> [DomainUsage] {
        var byHost = live
        for (host, totals) in history.hostTotals(appID: id, range: range) {
            var row = byHost[host] ?? DomainUsage(host: host, kind: totals.kind, rateDownKBps: 0,
                                                  totalDownKB: 0, totalUpKB: 0, connectionCount: 0)
            row.totalDownKB = totals.downKB
            row.totalUpKB = totals.upKB
            byHost[host] = row
        }
        return byHost.values
            .filter { $0.connectionCount > 0 || $0.rateDownKBps > 0 || $0.totalDownKB + $0.totalUpKB >= 1 }
            .sorted { $0.connectionCount > $1.connectionCount }
    }

    /// Re-reads every row's host totals for a newly chosen range, keeping
    /// what is open and moving now.
    private func refreshDomainTotals() {
        func refreshed(_ app: AppUsage) -> AppUsage {
            var app = app
            let live = app.domains.filter { $0.connectionCount > 0 || $0.rateDownKBps > 0 }.map { domain -> DomainUsage in
                var domain = domain
                domain.totalDownKB = 0
                domain.totalUpKB = 0
                return domain
            }
            app.domains = domainRows(for: app.id, live: Dictionary(live.map { ($0.host, $0) },
                                                                     uniquingKeysWith: { first, _ in first }))
            return app
        }
        apps = apps.map(refreshed)
        archivedApps = archivedApps.map(refreshed)
    }

    private func recordHost(appID: String, endpoint: String, _ kb: HostTotals) {
        let (host, kind) = describe(endpoint: endpoint)
        history.addHostDelta(appID: appID, endpoint: endpoint, host: host, kind: kind,
                             downKB: kb.downKB, upKB: kb.upKB)
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
    private static let forwardPrefix = "forward:"
    private static let sitePrefix = "site:"

    /// Endpoint key for a loopback connection to `port`. Seen from a local
    /// proxy, the far end is some app's ephemeral port — one row per port,
    /// dozens of them, each meaningless. Those fold into one row per app
    /// the proxy is forwarding for.
    private func loopbackEndpoint(port: Int, appID: String) -> String {
        if latestListeners[port] == nil, let client = loopbackPeer(port: port) {
            let app = identify(pid: client.pid, command: client.command)
            if app.id != appID {
                forwardedAppNames[app.id] = app.name
                return Self.forwardPrefix + app.id
            }
        }
        return Self.loopbackPrefix + String(port)
    }

    /// Apps listening on loopback that at least two other apps connect to:
    /// a local proxy (Shadowrocket, Clash, …) rather than a dev server one
    /// browser is talking to.
    private func findProxyApps() -> Set<String> {
        var clientsByListener: [Int32: Set<String>] = [:]
        for info in latestConnections.values {
            let client = identify(pid: info.pid, command: info.command).id
            for port in info.loopbackCounts.keys {
                guard let listener = latestListeners[port], listener.pid != info.pid else { continue }
                clientsByListener[listener.pid, default: []].insert(client)
            }
        }
        var proxies: Set<String> = []
        for (pid, clients) in clientsByListener {
            guard let command = latestListeners.values.first(where: { $0.pid == pid })?.command else { continue }
            let proxy = identify(pid: pid, command: command).id
            if clients.subtracting([proxy]).count >= 2 { proxies.insert(proxy) }
        }
        return proxies
    }

    /// Display name and kind for an endpoint key (a remote IP, `localhost:<port>`, …).
    private func describe(endpoint: String) -> (host: String, kind: String) {
        if endpoint.hasPrefix(Self.sitePrefix) {
            return (String(endpoint.dropFirst(Self.sitePrefix.count)), "经系统代理")
        }
        if endpoint == Self.closedEndpoint { return ("已关闭的连接", "连接已结束，无法再分到网站") }
        if endpoint == Self.unconnectedEndpoint { return ("无固定对端", "广播 / 本地发现") }
        if endpoint.hasPrefix(Self.forwardPrefix) {
            let appID = String(endpoint.dropFirst(Self.forwardPrefix.count))
            // The app's name alone: "为 Google Chrome 转发" got its name
            // cut in the middle in the host column.
            return (forwardedAppNames[appID] ?? appID, "代理转发")
        }
        if endpoint.hasPrefix(Self.loopbackPrefix),
           let port = Int(endpoint.dropFirst(Self.loopbackPrefix.count)) {
            // A machine running a local proxy sends most of a browser's
            // sockets to 127.0.0.1, where the destination is known only to
            // the proxy. Naming the process on the other end at least says
            // which one is carrying it.
            return (endpoint, loopbackPeerLabel(port: port))
        }
        let host = resolvedHosts[endpoint] ?? endpoint
        // 198.18.0.0/15 is where TUN-mode proxies (Shadowrocket, Clash, …)
        // hand out fake addresses, one per domain; the system resolver maps
        // them back to the domain the app asked for.
        if Self.isFakeIP(endpoint) {
            return (host, host == endpoint ? "经 TUN 代理" : "经 TUN 代理 · 已解析")
        }
        return (host, host == endpoint ? "IP 地址" : "已解析主机")
    }

    static func isFakeIP(_ ip: String) -> Bool {
        ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.")
    }

    /// The process on the far end of a loopback connection to `port` when
    /// nothing listens there, i.e. the client side of it.
    private func loopbackPeer(port: Int) -> ListenerInfo? {
        latestLoopbackClients[port] ?? nettopLoopbackPorts[port]
    }

    private func loopbackPeerLabel(port: Int) -> String {
        guard let listener = latestListeners[port] else {
            // The client end of a connection to one of this app's own ports.
            guard let client = loopbackPeer(port: port) else { return "本机进程" }
            let peer = identify(pid: client.pid, command: client.command)
            return "本机 · \(peer.name) · PID \(client.pid)"
        }
        let peer = identify(pid: listener.pid, command: listener.command)
        // The sites behind it, when its log is readable, are listed under
        // 经代理访问的网站.
        if proxyAppIDs.contains(peer.id) { return "经本机代理 · \(peer.name)" }
        return "本机 · \(peer.name)"
    }

    /// Per-second samples kept per app: enough for the longest RateWindow.
    static let historyLength = RateWindow.fifteenMinutes.seconds

    private func resort() {
        apps = ordered(withWindowRates(apps), force: true)
    }

    /// Fills in each app's average over `rateWindow` and its share of all
    /// apps' traffic in it. A proxy is left out of the shares: its bytes are
    /// the other apps' again.
    private func withWindowRates(_ list: [AppUsage]) -> [AppUsage] {
        // Right after launch a window isn't full yet; average over what
        // there is, the same for every app.
        let span = max(1, min(rateWindow.seconds, tickCount))
        var result = list.map { app -> AppUsage in
            var app = app
            app.windowDownKBps = app.downHistory.suffix(span).reduce(0, +) / Double(span)
            app.windowUpKBps = app.upHistory.suffix(span).reduce(0, +) / Double(span)
            return app
        }
        let total = result.filter { !$0.isProxy }.reduce(0) { $0 + $1.windowDownKBps + $1.windowUpKBps }
        for i in result.indices {
            let own = result[i].windowDownKBps + result[i].windowUpKBps
            result[i].windowShare = result[i].isProxy || total == 0 ? 0 : own / total
        }
        return result
    }

    /// Apps in list order. Under 实时速率 the order is only re-ranked every
    /// few seconds; in between, rows keep their places and only their
    /// numbers change, so the list can be read instead of chased.
    private var listOrder: [String] = []
    private static let reorderInterval = 3

    private func ordered(_ list: [AppUsage], force: Bool = false) -> [AppUsage] {
        let ranked = list.sorted(by: comparator(for: sortMode, range: range))
        if force || sortMode == .total || listOrder.isEmpty || tickCount % Self.reorderInterval == 0 {
            listOrder = ranked.map(\.id)
            return ranked
        }
        let place = Dictionary(listOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = ranked.enumerated().sorted { a, b in
            // New rows go below the ones already placed, in ranked order.
            let pa = place[a.element.id] ?? Int.max, pb = place[b.element.id] ?? Int.max
            if a.element.isProxy != b.element.isProxy { return b.element.isProxy }
            return (pa, a.offset) < (pb, b.offset)
        }.map(\.element)
        listOrder = kept.map(\.id)
        return kept
    }

    private func comparator(for sortMode: SortMode, range: TimeRange) -> (AppUsage, AppUsage) -> Bool {
        { lhs, rhs in
            // A proxy's traffic is the other apps' traffic again; at the top
            // it read as the biggest user.
            if lhs.isProxy != rhs.isProxy { return rhs.isProxy }
            if sortMode == .rate {
                let l = lhs.windowDownKBps + lhs.windowUpKBps, r = rhs.windowDownKBps + rhs.windowUpKBps
                if l != r { return l > r }
                return (lhs.rateDownKBps + lhs.rateUpKBps) > (rhs.rateDownKBps + rhs.rateUpKBps)
            }
            let l = (lhs.totalDownKB[range] ?? 0) + (lhs.totalUpKB[range] ?? 0)
            let r = (rhs.totalDownKB[range] ?? 0) + (rhs.totalUpKB[range] ?? 0)
            return l > r
        }
    }
}
