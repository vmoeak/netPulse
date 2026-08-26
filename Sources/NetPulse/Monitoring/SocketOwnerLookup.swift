import Foundation

/// Answers "which process opened this connection to our relay port?".
///
/// The relay needs it once per accepted connection, so a single `lsof` pass
/// over its own listening port is cached and refreshed on a miss — the
/// connection that just missed is exactly the one a refresh will find.
/// Refreshes are rate limited because a burst of new connections would
/// otherwise spawn a burst of lsof processes.
final class SocketOwnerLookup {
    private let listenPort: UInt16
    private let lock = NSLock()
    private var portToPID: [UInt16: Int32] = [:]
    private var lastRefresh = Date.distantPast
    private let minRefreshInterval: TimeInterval = 0.2

    init(listenPort: UInt16) {
        self.listenPort = listenPort
    }

    func pid(forSourcePort port: UInt16) -> Int32? {
        if let hit = cached(port) { return hit }
        refresh()
        return cached(port)
    }

    private func cached(_ port: UInt16) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        return portToPID[port]
    }

    private func refresh() {
        lock.lock()
        let due = Date().timeIntervalSince(lastRefresh) >= minRefreshInterval
        if due { lastRefresh = Date() }
        lock.unlock()
        guard due, let text = runLsof() else { return }

        var map: [UInt16: Int32] = [:]
        var pid: Int32?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value)
            case "n":
                // Both ends of the connection appear, one per process: the
                // client's socket reads "127.0.0.1:52341->127.0.0.1:1083" and
                // ours the other way round. Keeping only the rows whose
                // *remote* end is our port picks the client and skips us.
                guard let pid,
                      let (local, remote) = Self.splitConnection(value),
                      remote == listenPort,
                      let local else { continue }
                map[local] = pid
            default:
                break
            }
        }
        lock.lock()
        portToPID = map
        lock.unlock()
    }

    private func runLsof() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["lsof", "-nP", "-w",
                       "-iTCP@127.0.0.1:\(listenPort)", "-sTCP:ESTABLISHED",
                       "-F", "pn"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// "127.0.0.1:52341->127.0.0.1:1083" -> (52341, 1083)
    private static func splitConnection(_ name: String) -> (local: UInt16?, remote: UInt16)? {
        var value = name
        if let space = value.firstIndex(of: " ") { value = String(value[..<space]) }
        guard let arrow = value.range(of: "->") else { return nil }
        let local = port(of: String(value[..<arrow.lowerBound]))
        guard let remote = port(of: String(value[arrow.upperBound...])) else { return nil }
        return (local, remote)
    }

    private static func port(of endpoint: String) -> UInt16? {
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        return UInt16(endpoint[endpoint.index(after: colon)...])
    }
}
