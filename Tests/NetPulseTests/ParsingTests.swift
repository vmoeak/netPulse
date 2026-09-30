import XCTest
@testable import NetPulse

final class ParsingTests: XCTestCase {
    func testNettopRowKeepsSpacesInProcessName() throws {
        let row = try XCTUnwrap(NettopSampler.parseRow("Google Chrome H.1836     9087000    372112"))
        XCTAssertEqual(row.command, "Google Chrome H")
        XCTAssertEqual(row.pid, 1836)
        XCTAssertEqual(row.bytesIn, 9_087_000)
        XCTAssertEqual(row.bytesOut, 372_112)
    }

    func testNettopCSVRowSkipsTimestampCell() throws {
        let row = try XCTUnwrap(NettopSampler.parseRow("12:00:00.123456,mDNSResponder.595,100,200,"))
        XCTAssertEqual(row.command, "mDNSResponder")
        XCTAssertEqual(row.pid, 595)
        XCTAssertEqual(row.bytesIn, 100)
        XCTAssertEqual(row.bytesOut, 200)
    }

    func testNettopHeaderIsNotARow() {
        XCTAssertNil(NettopSampler.parseRow("time bytes_in bytes_out"))
    }

    func testNettopConnectionRows() {
        XCTAssertEqual(NettopSampler.parseLine("Lark Helper.1060        19025   20590\r"),
                       .process(NettopSampler.Row(command: "Lark Helper", pid: 1060, bytesIn: 19025, bytesOut: 20590)))
        XCTAssertEqual(NettopSampler.parseLine("   tcp4 192.168.1.5:49753<->203.0.113.7:443   19025   20590"),
                       .connection(key: "tcp4 192.168.1.5:49753<->203.0.113.7:443",
                                   NettopSampler.Connection(remoteHost: "203.0.113.7", remotePort: 443,
                                                            bytesIn: 19025, bytesOut: 20590)))
        guard case .connection(_, let v6) = NettopSampler.parseLine("   tcp6 ::1.50568<->::1.1082   10   20") else {
            return XCTFail("IPv6 row not recognized")
        }
        XCTAssertEqual(v6.remoteHost, "::1")
        XCTAssertEqual(v6.remotePort, 1082)
        XCTAssertTrue(v6.isLoopback)
        // A socket with no peer and no traffic yet prints no counters.
        guard case .connection(_, let idle) = NettopSampler.parseLine("   udp6 *.5353<->*.*") else {
            return XCTFail("counterless row not recognized")
        }
        XCTAssertEqual(idle.remoteHost, "*")
        XCTAssertEqual(idle.bytesIn, 0)
        XCTAssertEqual(NettopSampler.parseLine("                     bytes_in   bytes_out"), .other)
    }

    func testNettopConnectionSampleGroupsConnectionsUnderTheirProcess() {
        let text = """
                              bytes_in   bytes_out
        Lark Helper.1060        300   40
           tcp4 192.168.1.5:49753<->203.0.113.7:443   200   30
           tcp4 127.0.0.1:56826<->127.0.0.1:1082   100   10
        curl.77       5   5
           udp4 *:5353<->*:*
        """
        let samples = NettopSampler.parseConnectionSample(text)
        XCTAssertEqual(samples[1060]?.connections.count, 2)
        XCTAssertEqual(samples[1060]?.bytesInCumKB ?? 0, 300.0 / 1024, accuracy: 0.0001)
        XCTAssertEqual(samples[77]?.connections.values.first?.remoteHost, "*")
    }

    func testLsofFieldOutput() throws {
        let text = """
        p123
        cSafari
        f10
        PTCP
        n192.168.1.5:53482->172.217.14.234:443
        f11
        PTCP
        n127.0.0.1:50000->127.0.0.1:7890
        f12
        PUDP
        n*:5353
        p456
        cClashX Pro
        f5
        PTCP
        n127.0.0.1:7890
        f6
        PTCP
        n[::1]:7890
        """
        let snapshot = ConnectionSampler.parse(text)
        XCTAssertEqual(snapshot.connections.count, 1, "a process with only listeners has no connections")
        let safari = try XCTUnwrap(snapshot.connections.first)
        XCTAssertEqual(safari.pid, 123)
        XCTAssertEqual(safari.remoteCounts, ["172.217.14.234": 1])
        XCTAssertEqual(safari.loopbackCounts, [7890: 1])
        XCTAssertEqual(snapshot.listeners[7890]?.pid, 456)
        XCTAssertEqual(snapshot.listeners[7890]?.command, "ClashX Pro")
        XCTAssertNil(snapshot.listeners[5353], "UDP sockets are not listeners")
        XCTAssertEqual(snapshot.loopbackClients[50000]?.pid, 123, "the proxy's peer port names Safari")
    }
}

final class ProcessNameTests: XCTestCase {
    func testRetitledCommandLineLosesItsArguments() {
        XCTAssertEqual(ProcessDirectory.sanitizedCommand("npm exec @scope/tool --token=abc123 --verbose", pid: 42),
                       "npm")
    }

    func testRetitledCommandLineWithoutFlagsIsCutToItsProgram() {
        XCTAssertEqual(ProcessDirectory.sanitizedCommand("npm exec @mastergo/magic-mcp mg_secret123", pid: 42), "npm")
        XCTAssertEqual(ProcessDirectory.sanitizedCommand("/usr/local/bin/node server.js", pid: 42), "node")
    }

    func testPlainNamesAreKept() {
        XCTAssertEqual(ProcessDirectory.sanitizedCommand("Google Chrome H", pid: 42), "Google Chrome H")
        XCTAssertEqual(ProcessDirectory.sanitizedCommand("", pid: 42), "pid-42")
    }

    func testLiveProcessIsNamedAfterItsExecutable() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let name = ProcessDirectory.processName(pid: pid, command: "whatever --secret=1")
        XCTAssertFalse(name.contains("secret"))
        XCTAssertFalse(name.isEmpty)
    }
}

final class HistoryPurgeTests: XCTestCase {
    func testCommandLineIDsSavedByOlderBuildsArePurged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let leaky = "proc.npm exec @mastergo/magic-mcp mg_secret123"
        let first = HistoryStore(directory: dir)
        first.addDelta(appID: leaky, downKB: 10, upKB: 1)
        first.rememberName("npm exec @mastergo/magic-mcp mg_secret123", for: leaky)
        first.addDelta(appID: "proc.Google Chrome H", downKB: 10, upKB: 1)
        first.saveIfDirty()

        let reloaded = HistoryStore(directory: dir)
        XCTAssertEqual(reloaded.rollup(appID: leaky, range: .all).downKB, 0)
        XCTAssertNil(reloaded.name(for: leaky))
        XCTAssertEqual(reloaded.rollup(appID: "proc.Google Chrome H", range: .all).downKB, 10)
        for file in ["history.json", "app-names.json"] {
            let text = try String(contentsOf: dir.appendingPathComponent(file))
            XCTAssertFalse(text.contains("mg_secret123"), "\(file) still holds the token")
        }
    }

    /// Bundle-less apps were saved as "pid.<n>" under their process title.
    func testPidIDsSavedByOlderBuildsArePurged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = HistoryStore(directory: dir)
        first.addDelta(appID: "pid.4242", downKB: 10, upKB: 1)
        first.rememberName("node mcp mg_secret123", for: "pid.4242")
        first.saveIfDirty()

        let reloaded = HistoryStore(directory: dir)
        XCTAssertEqual(reloaded.rollup(appID: "pid.4242", range: .all).downKB, 0)
        XCTAssertNil(reloaded.name(for: "pid.4242"))
        for file in ["history.json", "app-names.json"] {
            let text = try String(contentsOf: dir.appendingPathComponent(file))
            XCTAssertFalse(text.contains("mg_secret123"), "\(file) still holds the token")
        }
    }
}
