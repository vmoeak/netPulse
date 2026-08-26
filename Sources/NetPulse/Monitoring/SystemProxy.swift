import Foundation

/// Reads the machine's current HTTP proxy setting, which is where the relay
/// has to forward to. Read-only on purpose: switching the system proxy needs
/// an admin prompt and leaves the machine pointing at NetPulse, so that step
/// stays in the user's hands until they have seen the relay work.
enum SystemProxy {
    struct Upstream: Equatable {
        let host: String
        let port: UInt16

        var description: String { "\(host):\(port)" }
    }

    static func current() -> Upstream? {
        guard let text = runScutil() else { return nil }
        var host: String?
        var port: UInt16?
        var enabled = false
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "HTTPEnable": enabled = value == "1"
            case "HTTPProxy": host = value
            case "HTTPPort": port = UInt16(value)
            default: break
            }
        }
        guard enabled, let host, let port else { return nil }
        return Upstream(host: host, port: port)
    }

    private static func runScutil() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["scutil", "--proxy"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
