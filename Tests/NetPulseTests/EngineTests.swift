import XCTest
@testable import NetPulse

/// Canned nettop output: tests set `samples` and call `tick()` themselves.
private final class FakeNettop: NettopSource {
    var onStatusChange: ((MonitoringStatus) -> Void)?
    var samples: [Int32: NettopSampler.Sample] = [:]
    private(set) var forgotten: Set<Int32> = []

    func start() {}
    func stop() {}
    func snapshot() -> [Int32: NettopSampler.Sample] { samples }
    func forget(pids: Set<Int32>) {
        forgotten.formUnion(pids)
        for pid in pids { samples.removeValue(forKey: pid) }
    }
}

/// Drives `NetworkMonitorEngine` with fake nettop/lsof data. Processes that
/// must count as alive are real `sleep` processes, because the engine
/// checks liveness with kill(pid, 0); a pid well above macOS's limit
/// stands in for one that has exited.
@MainActor
final class EngineTests: XCTestCase {
    private var nettop: FakeNettop!
    private var engine: NetworkMonitorEngine!
    private var history: HistoryStore!
    private var sleepers: [Process] = []
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        nettop = FakeNettop()
        history = HistoryStore(directory: tempDir)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NetPulseTests-\(UUID().uuidString)"))
        // Every live pid here is a `sleep`, so name them after the canned
        // command instead of their executable.
        engine = NetworkMonitorEngine(nettop: nettop, connections: ConnectionSampler(),
                                      history: history, defaults: defaults,
                                      identify: { _, command in
                                          ProcessDirectory.Identity(id: "proc." + command, name: command,
                                                                    bundleID: "proc." + command,
                                                                    statusHint: "后台进程")
                                      })
    }

    override func tearDown() async throws {
        sleepers.forEach { $0.terminate() }
        sleepers = []
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func livePID() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        sleepers.append(p)
        return p.processIdentifier
    }

    private func feed(_ pid: Int32, _ command: String, downKB: Double, upKB: Double = 0) {
        nettop.samples[pid] = NettopSampler.Sample(pid: pid, command: command,
                                                   bytesInCumKB: downKB, bytesOutCumKB: upKB)
    }

    private func feed(_ pid: Int32, _ command: String, downKB: Double,
                      connections: [String: (host: String, downKB: Double)]) {
        var sample = NettopSampler.Sample(pid: pid, command: command, bytesInCumKB: downKB, bytesOutCumKB: 0)
        for (key, conn) in connections {
            sample.connections[key] = NettopSampler.Connection(remoteHost: conn.host, remotePort: 443,
                                                               bytesIn: conn.downKB * 1024, bytesOut: 0)
        }
        nettop.samples[pid] = sample
    }

    private func app(_ id: String) -> AppUsage? {
        engine.apps.first { $0.id == id }
    }

    func testConnectionCountersSplitBytesExactlyByHost() throws {
        let pid = try livePID()
        feed(pid, "alpha", downKB: 100, connections: ["a": ("192.0.2.10", 60), "b": ("198.18.0.23", 40)])
        engine.tick()
        // a grows by 30, b by 50, c is new with 15, and 5 went through one
        // that closed in between.
        feed(pid, "alpha", downKB: 200, connections: ["a": ("192.0.2.10", 90), "b": ("198.18.0.23", 90),
                                                      "c": ("192.0.2.10", 15)])
        engine.tick()
        let domains = Dictionary(uniqueKeysWithValues: (app("proc.alpha")?.domains ?? []).map { ($0.host, $0) })
        XCTAssertEqual(domains["192.0.2.10"]?.rateDownKBps ?? 0, 45, accuracy: 0.001)
        XCTAssertEqual(domains["192.0.2.10"]?.connectionCount, 2)
        XCTAssertEqual(domains["198.18.0.23"]?.rateDownKBps ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(domains["198.18.0.23"]?.kind, "经 TUN 代理")
        XCTAssertEqual(domains["已关闭的连接"]?.totalDownKB ?? 0, 5, accuracy: 0.001)
        XCTAssertFalse(engine.domainRollups.contains { $0.host == "已关闭的连接" })
    }

    func testHostsDisappearWhenProcessClosesItsSockets() throws {
        let pid = try livePID()
        feed(pid, "alpha", downKB: 0)
        engine.ingestConnections(ConnectionSnapshot(
            connections: [ConnectionInfo(pid: pid, command: "alpha",
                                         remoteCounts: ["192.0.2.10": 2], loopbackCounts: [:])],
            listeners: [:]))
        engine.tick()
        XCTAssertEqual(app("proc.alpha")?.domains.count, 1)
        XCTAssertEqual(app("proc.alpha")?.connectionCount, 2)

        // lsof no longer lists the process at all once its sockets are closed.
        engine.ingestConnections(ConnectionSnapshot(connections: [], listeners: [:]))
        engine.tick()
        XCTAssertEqual(app("proc.alpha")?.domains, [])
        XCTAssertEqual(app("proc.alpha")?.connectionCount, 0)
        XCTAssertTrue(engine.connectionRows.isEmpty)
    }

    func testHostTotalsOutliveTheirConnections() throws {
        let pid = try livePID()
        feed(pid, "alpha", downKB: 0)
        engine.ingestConnections(ConnectionSnapshot(
            connections: [ConnectionInfo(pid: pid, command: "alpha",
                                         remoteCounts: ["192.0.2.10": 1], loopbackCounts: [:])],
            listeners: [:]))
        engine.tick()
        feed(pid, "alpha", downKB: 300)
        engine.tick()
        engine.ingestConnections(ConnectionSnapshot(connections: [], listeners: [:]))
        engine.tick()

        let rollup = try XCTUnwrap(engine.domainRollups.first)
        XCTAssertEqual(rollup.totalDownKB, 300, accuracy: 0.001)
        XCTAssertEqual(rollup.connectionCount, 0)
        XCTAssertEqual(rollup.appNames, ["alpha"])
    }

    func testExitedAppDropsToZeroButKeepsTotals() throws {
        let pid = try livePID()
        feed(pid, "beta", downKB: 0, upKB: 0)
        engine.tick()
        feed(pid, "beta", downKB: 2048, upKB: 64)
        engine.tick()
        XCTAssertEqual(app("proc.beta")?.rateDownKBps ?? 0, 2048, accuracy: 0.001)
        XCTAssertEqual(engine.totalDownKBps, 2048, accuracy: 0.001)

        nettop.samples.removeValue(forKey: pid)
        let other = try livePID()
        feed(other, "other", downKB: 0) // keeps the tick from bailing out on no data
        engine.tick()
        let beta = try XCTUnwrap(app("proc.beta"))
        XCTAssertEqual(beta.rateDownKBps, 0)
        XCTAssertEqual(beta.rateUpKBps, 0)
        XCTAssertEqual(beta.statusLine, "未运行")
        XCTAssertEqual(beta.totalDownKB[.today] ?? 0, 2048, accuracy: 0.001)
        XCTAssertEqual(engine.totalDownKBps, 0, accuracy: 0.001)
    }

    func testExitedAppThatNeverMovedABytesIsDropped() throws {
        let pid = try livePID()
        feed(pid, "idle", downKB: 10)
        engine.tick()
        XCTAssertNotNil(app("proc.idle"))
        nettop.samples.removeValue(forKey: pid)
        let other = try livePID()
        feed(other, "other", downKB: 0)
        engine.tick()
        XCTAssertNil(app("proc.idle"))
    }

    func testPausedAppStopsCountingAndShowsZero() throws {
        let pid = try livePID()
        feed(pid, "gamma", downKB: 0)
        engine.tick()
        feed(pid, "gamma", downKB: 100)
        engine.tick()
        engine.togglePause(appID: "proc.gamma")
        feed(pid, "gamma", downKB: 5000)
        engine.tick()

        let gamma = try XCTUnwrap(app("proc.gamma"))
        XCTAssertTrue(gamma.isPaused)
        XCTAssertEqual(gamma.rateDownKBps, 0)
        XCTAssertEqual(gamma.statusLine, "已暂停统计")
        XCTAssertEqual(history.rollup(appID: "proc.gamma", range: .today).downKB, 100, accuracy: 0.001)

        // Resuming counts from where the counters are now, not a 4900 KB burst.
        engine.togglePause(appID: "proc.gamma")
        feed(pid, "gamma", downKB: 5010)
        engine.tick()
        XCTAssertEqual(app("proc.gamma")?.rateDownKBps ?? 0, 10, accuracy: 0.001)
    }

    func testExitedPIDsAreForgotten() throws {
        let gone: Int32 = 999_999
        feed(gone, "ghost", downKB: 1)
        let alive = try livePID()
        feed(alive, "alive", downKB: 1)
        for _ in 0..<5 { engine.tick() }
        XCTAssertEqual(nettop.forgotten, [gone])
    }

    func testLoopbackPeerIsNamedAfterTheListener() throws {
        let pid = try livePID()
        feed(pid, "browser", downKB: 0)
        engine.ingestConnections(ConnectionSnapshot(
            connections: [ConnectionInfo(pid: pid, command: "browser",
                                         remoteCounts: [:], loopbackCounts: [7890: 3])],
            listeners: [7890: ListenerInfo(pid: 999_998, command: "clashx")]))
        engine.tick()
        let domain = try XCTUnwrap(app("proc.browser")?.domains.first)
        XCTAssertEqual(domain.host, "localhost:7890")
        XCTAssertEqual(domain.kind, "本机 · clashx")
    }

    func testAppsThatAreNotRunningAppearUnderTotals() throws {
        history.addDelta(appID: "proc.gone", downKB: 500, upKB: 10)
        history.rememberName("Gone", for: "proc.gone")
        let alive = try livePID()
        feed(alive, "alive", downKB: 0)
        engine.tick()

        XCTAssertFalse(engine.listedApps.contains { $0.id == "proc.gone" }, "rate view lists live apps only")
        engine.sortMode = .total
        let gone = try XCTUnwrap(engine.listedApps.first { $0.id == "proc.gone" })
        XCTAssertFalse(gone.isLive)
        XCTAssertEqual(gone.name, "Gone")
        XCTAssertEqual(gone.totalDownKB[.week] ?? 0, 500, accuracy: 0.001)

        engine.select(appID: "proc.gone")
        engine.tick()
        XCTAssertEqual(engine.selectedApp?.id, "proc.gone", "selecting an archived app survives a tick")
    }

    func testMeterScalesToRecentPeak() throws {
        let pid = try livePID()
        feed(pid, "delta", downKB: 0)
        engine.tick()
        feed(pid, "delta", downKB: 4096)
        engine.tick()
        XCTAssertEqual(engine.totalDownPct, 1, accuracy: 0.001)
        feed(pid, "delta", downKB: 6144)
        engine.tick()
        XCTAssertEqual(engine.totalDownPct, 0.5, accuracy: 0.001)
    }

    func testAppsThatNeverMovedAByteAreHiddenUntilAskedFor() throws {
        let idle = try livePID(), busy = try livePID()
        feed(idle, "idled", downKB: 0)
        feed(busy, "busy", downKB: 0)
        engine.tick()
        feed(busy, "busy", downKB: 100)
        engine.tick()

        XCTAssertEqual(engine.listedApps.map(\.id), ["proc.busy"])
        XCTAssertEqual(engine.hiddenIdleCount, 1)
        XCTAssertEqual(engine.selectedAppID, "proc.busy", "opens on the app that is moving traffic")
        engine.showIdleApps = true
        XCTAssertEqual(Set(engine.listedApps.map(\.id)), ["proc.busy", "proc.idled"])
        XCTAssertEqual(engine.hiddenIdleCount, 0)
    }

    /// Chrome and Code reach the net through a local proxy on 1082: the
    /// proxy's dozens of ephemeral-port rows fold into one per app, and its
    /// bytes (theirs, forwarded) stay out of the machine totals.
    func testLocalProxyRowsFoldPerAppAndStayOutOfTotals() throws {
        let proxy = try livePID(), chrome = try livePID(), code = try livePID()
        for (pid, name) in [(proxy, "tunnel"), (chrome, "chrome"), (code, "code")] { feed(pid, name, downKB: 0) }
        engine.ingestConnections(ConnectionSnapshot(
            connections: [
                ConnectionInfo(pid: chrome, command: "chrome", remoteCounts: [:], loopbackCounts: [1082: 2]),
                ConnectionInfo(pid: code, command: "code", remoteCounts: [:], loopbackCounts: [1082: 1]),
                ConnectionInfo(pid: proxy, command: "tunnel", remoteCounts: ["192.0.2.1": 3],
                               loopbackCounts: [51001: 1, 51002: 1, 51003: 1]),
            ],
            listeners: [1082: ListenerInfo(pid: proxy, command: "tunnel")],
            loopbackClients: [51001: ListenerInfo(pid: chrome, command: "chrome"),
                              51002: ListenerInfo(pid: chrome, command: "chrome"),
                              51003: ListenerInfo(pid: code, command: "code")]))
        engine.tick()
        feed(chrome, "chrome", downKB: 100)
        feed(code, "code", downKB: 50)
        feed(proxy, "tunnel", downKB: 150)
        engine.tick()

        let tunnel = try XCTUnwrap(app("proc.tunnel"))
        XCTAssertTrue(tunnel.isProxy)
        XCTAssertEqual(Set(tunnel.domains.map(\.host)), ["192.0.2.1", "chrome", "code"])
        XCTAssertEqual(tunnel.domains.first { $0.host == "chrome" }?.connectionCount, 2)
        XCTAssertEqual(engine.apps.last?.id, "proc.tunnel", "the proxy sorts below the apps it forwards for")
        XCTAssertEqual(engine.totalDownKBps, 150, accuracy: 0.001, "the proxy's forwarded bytes are not counted twice")
        XCTAssertEqual(engine.topApp?.id, "proc.chrome")
        XCTAssertFalse(engine.domainRollups.contains { $0.host == "chrome" || $0.host == "code" })
        XCTAssertEqual(app("proc.chrome")?.domains.first?.host, "localhost:1082")
    }

    /// A one-second burst doesn't reorder the list; the window average does,
    /// and only on a re-rank tick.
    func testRateRankingUsesTheWindowAndHoldsOrderBetweenReranks() throws {
        let steady = try livePID(), bursty = try livePID()
        var steadyKB = 0.0, burstyKB = 0.0
        feed(steady, "steady", downKB: 0)
        feed(bursty, "bursty", downKB: 0)
        engine.tick()                                   // tick 1: baseline
        for _ in 0..<4 {                                // ticks 2-5: steady 100 KB/s
            steadyKB += 100
            feed(steady, "steady", downKB: steadyKB)
            engine.tick()
        }
        XCTAssertEqual(engine.apps.first?.id, "proc.steady")

        burstyKB += 300                                 // tick 6: one 300 KB burst
        steadyKB += 100
        feed(bursty, "bursty", downKB: burstyKB)
        feed(steady, "steady", downKB: steadyKB)
        engine.tick()
        XCTAssertEqual(engine.apps.first?.id, "proc.steady",
                       "a single-second burst doesn't outrank 5 seconds of steady traffic")
        let steadyRow = try XCTUnwrap(app("proc.steady"))
        // 实时 averages 10 s; 6 ticks so far, so over 6.
        XCTAssertEqual(steadyRow.windowDownKBps, 500.0 / 6.0, accuracy: 0.001)
        XCTAssertEqual(steadyRow.windowShare, 500.0 / 800.0, accuracy: 0.001)

        burstyKB += 3000                                // tick 7: no re-rank yet
        feed(bursty, "bursty", downKB: burstyKB)
        engine.tick()
        XCTAssertEqual(app("proc.steady")?.windowShare ?? 0, 500.0 / 800.0, accuracy: 0.001,
                       "shares hold with the order between re-ranks")
        XCTAssertEqual(engine.apps.first?.id, "proc.steady")

        engine.rateWindow = .oneMinute
        XCTAssertEqual(app("proc.steady")?.windowDownKBps ?? 0, 500.0 / 7.0, accuracy: 0.001,
                       "averaged over the 7 ticks seen so far")
        XCTAssertEqual(engine.apps.first?.id, "proc.bursty", "a new window re-ranks at once")
    }

    func testStackAndTopAppsSplitTrafficByApp() throws {
        let pids = try (0..<7).map { _ in try livePID() }
        for (n, pid) in pids.enumerated() { feed(pid, "app\(n)", downKB: 0) }
        engine.tick()
        for step in 1...3 {
            // app0 moves the most, app6 the least.
            for (n, pid) in pids.enumerated() { feed(pid, "app\(n)", downKB: Double(step * (70 - n * 10))) }
            engine.tick()
        }
        let layers = engine.stackLayers(top: 5, buckets: 90)
        XCTAssertEqual(layers.map(\.name), ["app0", "app1", "app2", "app3", "app4", "其他"])
        XCTAssertEqual(layers.last?.values.last ?? 0, 20 + 10, accuracy: 0.001, "其他 sums app5 and app6")
        XCTAssertEqual(engine.topApps(over: .fiveMinutes, count: 3).map(\.app.id), ["proc.app0", "proc.app1", "proc.app2"])
    }
}
