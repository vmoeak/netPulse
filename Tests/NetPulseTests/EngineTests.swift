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
        engine = NetworkMonitorEngine(nettop: nettop, connections: ConnectionSampler(),
                                      history: history, defaults: defaults)
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

    private func app(_ id: String) -> AppUsage? {
        engine.apps.first { $0.id == id }
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
        XCTAssertEqual(beta.statusLine, "已退出")
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
}
