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
    }
}
