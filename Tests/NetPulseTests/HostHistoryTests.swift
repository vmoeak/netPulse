import XCTest
@testable import NetPulse

/// Per-host bytes kept by day, so 域名明细 matches the range-based tiles
/// above it instead of restarting at zero each launch.
final class HostHistoryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testHostTotalsSurviveARelaunch() throws {
        let first = HistoryStore(directory: dir)
        first.addHostDelta(appID: "app", endpoint: "192.0.2.10", host: "192.0.2.10", kind: "IP 地址",
                           downKB: 100, upKB: 40)
        first.saveIfDirty()

        let second = HistoryStore(directory: dir)
        second.addHostDelta(appID: "app", endpoint: "192.0.2.10", host: "192.0.2.10", kind: "IP 地址",
                            downKB: 10, upKB: 5)
        let host = try XCTUnwrap(second.hostTotals(appID: "app", range: .today)["192.0.2.10"])
        XCTAssertEqual(host.downKB, 110, accuracy: 0.001)
        XCTAssertEqual(host.upKB, 45, accuracy: 0.001)

        // Saving again rewrites today's file without counting the first
        // launch's bytes twice.
        second.saveIfDirty()
        let third = HistoryStore(directory: dir)
        XCTAssertEqual(third.hostTotals(appID: "app", range: .week)["192.0.2.10"]?.upKB ?? 0, 45, accuracy: 0.001)
    }

    func testRelabelMovesBytesToTheResolvedName() {
        let store = HistoryStore(directory: dir)
        store.addHostDelta(appID: "app", endpoint: "192.0.2.10", host: "192.0.2.10", kind: "IP 地址",
                           downKB: 30, upKB: 0)
        store.relabelHosts { $0 == "192.0.2.10" ? ("example.com", "已解析主机") : nil }
        let hosts = store.hostTotals(appID: "app", range: .today)
        XCTAssertNil(hosts["192.0.2.10"])
        XCTAssertEqual(hosts["example.com"]?.downKB ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(hosts["example.com"]?.kind, "已解析主机")
    }
}
