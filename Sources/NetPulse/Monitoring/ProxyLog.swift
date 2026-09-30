import Foundation
import SQLite3

/// One site an app reached through the local proxy, from the proxy's log.
struct ProxyVisit: Identifiable, Equatable {
    var id: String { host }
    var host: String
    /// "PROXY" or "DIRECT": the policy the proxy's rules picked.
    var policy: String
    /// The rule that matched, e.g. "DOMAIN-SUFFIX,icloud.com".
    var rule: String
    var count: Int
    /// Local time of the latest visit, "HH:mm:ss".
    var lastSeen: String
}

/// Reads Shadowrocket's proxy log so an app's detail can list the sites it
/// reached through the proxy — something connection data can't show, since
/// the app only ever talks to the proxy. The user opted in to this.
///
/// The log has no pid or port, only each request's User-Agent, so sites are
/// grouped by the product the UA names ("Code", "Lark", plain Chrome…).
/// Raw TUN connections carry no UA ("TCP Stream", "UDP Relay") and are
/// grouped under `unattributed`. Nothing read here is saved to disk.
final class ProxyLogReader {
    static let shadowrocketLogs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.liguangming.Shadowrocket/Library/Caches/Logs")
    static let unattributed = ""

    private let directory: URL
    private var currentFile: String?
    private var lastDocID: Int64 = 0
    /// UA product key -> host -> visit.
    private(set) var visitsByProduct: [String: [String: ProxyVisit]] = [:]
    private static let maxHostsPerProduct = 200

    init(directory: URL = ProxyLogReader.shadowrocketLogs) {
        self.directory = directory
    }

    /// Pulls rows added since the last call. Returns false when there is no
    /// log to read (Shadowrocket not installed, or macOS withheld access).
    @discardableResult
    func refresh() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let newest = files.filter({ $0.hasPrefix("proxy-") && $0.hasSuffix(".db") }).sorted().last
        else { return false }
        // Shadowrocket starts a new log each time it connects.
        if newest != currentFile {
            currentFile = newest
            lastDocID = -1
            visitsByProduct = [:]
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent(newest).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        if lastDocID < 0 {
            // A fresh file: start from its latest rows, not its whole history.
            lastDocID = max(0, (Self.scalar(db, "SELECT max(docid) FROM logging_content") ?? 0) - 2000)
        }
        // logging is an FTS3 table; its plain content table needs no tokenizer.
        let sql = "SELECT docid, c0url, c1ua, c2result, c3type, c4created FROM logging_content WHERE docid > ? ORDER BY docid LIMIT 5000"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastDocID)
        while sqlite3_step(stmt) == SQLITE_ROW {
            lastDocID = sqlite3_column_int64(stmt, 0)
            record(url: Self.text(stmt, 1), ua: Self.text(stmt, 2), result: Self.text(stmt, 3),
                   policy: Self.text(stmt, 4), created: Self.text(stmt, 5))
        }
        return true
    }

    func record(url: String, ua: String, result: String, policy: String, created: String) {
        let host = Self.host(fromURL: url)
        guard !host.isEmpty else { return }
        let product = Self.productKey(fromUA: ua)
        // "FINAL,PROXY # vless-reality" → rule "FINAL"; the node name after
        // "#" is left out.
        let ruleParts = (result.components(separatedBy: " #").first ?? result).split(separator: ",")
        let rule = ruleParts.dropLast().joined(separator: ",")
        let time = created.split(separator: " ").last.map(String.init) ?? created
        var visits = visitsByProduct[product] ?? [:]
        var visit = visits[host] ?? ProxyVisit(host: host, policy: policy, rule: rule, count: 0, lastSeen: time)
        visit.count += 1
        visit.policy = policy
        visit.rule = rule
        visit.lastSeen = time
        visits[host] = visit
        if visits.count > Self.maxHostsPerProduct,
           let oldest = visits.values.min(by: { $0.lastSeen < $1.lastSeen }) {
            visits.removeValue(forKey: oldest.host)
        }
        visitsByProduct[product] = visits
    }

    /// "example.com:443" → "example.com"; the log's urls carry no scheme.
    static func host(fromURL url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespaces)
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            return String(s[s.index(after: s.startIndex)..<close])
        }
        if let colon = s.lastIndex(of: ":"), s.filter({ $0 == ":" }).count == 1 { s = String(s[..<colon]) }
        return s.lowercased()
    }

    /// Engine and wrapper tokens every browser-based UA repeats; what is
    /// left names the app ("Code/1.138.0", "Lark/8.1.17", "git/2.50.1").
    private static let genericProducts: Set<String> = [
        "mozilla", "applewebkit", "chrome", "safari", "electron", "version", "mobile",
        "gecko", "larklocale", "sdk-version", "cronet", "ttnetversion", "quicversion",
    ]

    /// Lowercased product the UA names, "google chrome" for a plain Chrome
    /// UA, or `unattributed` for TUN connections, which have none.
    static func productKey(fromUA ua: String) -> String {
        let trimmed = ua.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "TCP Stream", trimmed != "UDP Relay" else { return unattributed }
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ")" || $0 == ";" })
            .compactMap { token -> String? in
                guard let slash = token.firstIndex(of: "/"), slash != token.startIndex else { return nil }
                return token[..<slash].lowercased()
            }
        if let named = tokens.first(where: { !genericProducts.contains($0) }) { return named }
        return tokens.contains("chrome") ? "google chrome" : unattributed
    }

    /// UA products whose name differs from the app NetPulse lists them as.
    private static let productAliases: [String: [String]] = [
        "google chrome": ["com.google.chrome"],
        "code": ["com.microsoft.vscode"],
        "codex_vscode": ["com.microsoft.vscode"],
        "codex_cli_rs": ["proc.codex"],
        "lark": ["com.electron.lark", "com.bytedance.lark", "飞书", "feishu", "lark"],
        "claude": ["com.anthropic.claudefordesktop"],
        "com.apple.trustd": ["proc.trustd"],
    ]

    /// The UA products that belong to an app with this id and name.
    static func products(forAppID id: String, name: String, in keys: some Sequence<String>) -> [String] {
        let lowerID = id.lowercased(), lowerName = name.lowercased()
        let lastComponent = lowerID.split(separator: ".").last.map(String.init) ?? lowerID
        return keys.filter { key in
            guard key != unattributed else { return false }
            if let aliases = productAliases[key],
               aliases.contains(where: { $0 == lowerID || $0 == lowerName }) { return true }
            return key == lowerName || key == lastComponent || "proc." + key == lowerID
        }
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    private static func scalar(_ db: OpaquePointer?, _ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }
}
