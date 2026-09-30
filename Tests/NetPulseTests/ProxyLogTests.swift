import XCTest
import SQLite3
@testable import NetPulse

final class ProxyLogTests: XCTestCase {
    func testUserAgentsNameTheirApp() {
        let chrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36"
        let code = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Code/1.138.0 Chrome/148.0.7778.280 Electron/42.10.0 Safari/537.36"
        let lark = "Mozilla/5.0 (Macintosh; Intel Mac OS X 26_3_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.7727.149 Safari/537.36 Lark/8.1.17 LarkLocale/zh_CN ttnet SDK-Version/8.1.9"
        XCTAssertEqual(ProxyLogReader.productKey(fromUA: chrome), "google chrome")
        XCTAssertEqual(ProxyLogReader.productKey(fromUA: code), "code")
        XCTAssertEqual(ProxyLogReader.productKey(fromUA: lark), "lark")
        XCTAssertEqual(ProxyLogReader.productKey(fromUA: "git/2.50.1"), "git")
        XCTAssertEqual(ProxyLogReader.productKey(fromUA: "codex_cli_rs/0.156.1 (Mac OS 26.3.0; arm64) unknown"), "codex_cli_rs")
        XCTAssertEqual(ProxyLogReader.productKey(fromUA: "TCP Stream"), ProxyLogReader.unattributed)
        XCTAssertEqual(ProxyLogReader.productKey(fromUA: "UDP Relay"), ProxyLogReader.unattributed)
    }

    func testProductsMatchApps() {
        let keys = ["google chrome", "code", "codex_vscode", "git", "lark", ProxyLogReader.unattributed]
        XCTAssertEqual(Set(ProxyLogReader.products(forAppID: "com.microsoft.VSCode", name: "Code", in: keys)),
                       ["code", "codex_vscode"])
        XCTAssertEqual(ProxyLogReader.products(forAppID: "com.google.Chrome", name: "Google Chrome", in: keys),
                       ["google chrome"])
        XCTAssertEqual(ProxyLogReader.products(forAppID: "proc.git", name: "git", in: keys), ["git"])
        XCTAssertEqual(ProxyLogReader.products(forAppID: "com.electron.lark", name: "飞书", in: keys), ["lark"])
        XCTAssertEqual(ProxyLogReader.products(forAppID: "proc.mDNSResponder", name: "mDNSResponder", in: keys), [])
    }

    func testHostDropsPort() {
        XCTAssertEqual(ProxyLogReader.host(fromURL: "Example.com:443"), "example.com")
        XCTAssertEqual(ProxyLogReader.host(fromURL: "http://example.com/path"), "example.com")
        XCTAssertEqual(ProxyLogReader.host(fromURL: "[2001:db8::1]:443"), "2001:db8::1")
    }

    /// A log shaped like Shadowrocket's: read incrementally, visits grouped
    /// by UA product and host.
    func testRefreshReadsNewRowsFromTheNewestLog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("proxy-2026-09-30-222000.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        exec("CREATE TABLE logging_content(docid INTEGER PRIMARY KEY, c0url, c1ua, c2result, c3type, c4created)")
        exec("INSERT INTO logging_content VALUES (1, 'example.com:443', 'git/2.50.1', 'FINAL,PROXY # node', 'PROXY', '2026-09-30 22:57:51')")
        exec("INSERT INTO logging_content VALUES (2, 'example.com:443', 'git/2.50.1', 'FINAL,PROXY # node', 'PROXY', '2026-09-30 22:57:53')")
        exec("INSERT INTO logging_content VALUES (3, 'icloud.com:443', 'TCP Stream', 'DOMAIN-SUFFIX,icloud.com,DIRECT', 'DIRECT', '2026-09-30 22:57:52')")

        let reader = ProxyLogReader(directory: dir)
        XCTAssertTrue(reader.refresh())
        let git = try XCTUnwrap(reader.visitsByProduct["git"]?["example.com"])
        XCTAssertEqual(git.count, 2)
        XCTAssertEqual(git.policy, "PROXY")
        XCTAssertEqual(git.rule, "FINAL")
        XCTAssertEqual(git.lastSeen, "22:57:53")
        let tun = try XCTUnwrap(reader.visitsByProduct[ProxyLogReader.unattributed]?["icloud.com"])
        XCTAssertEqual(tun.rule, "DOMAIN-SUFFIX,icloud.com")
        XCTAssertEqual(tun.policy, "DIRECT")

        exec("INSERT INTO logging_content VALUES (4, 'example.com:443', 'git/2.50.1', 'FINAL,PROXY # node', 'PROXY', '2026-09-30 22:58:00')")
        reader.refresh()
        XCTAssertEqual(reader.visitsByProduct["git"]?["example.com"]?.count, 3, "only the new row is added")
    }

    func testNoLogMeansNothingToRead() {
        let reader = ProxyLogReader(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertFalse(reader.refresh())
        XCTAssertTrue(reader.visitsByProduct.isEmpty)
    }
}
