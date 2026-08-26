import AppKit

/// Resolves a pid (from nettop) to a stable app identity. GUI apps go
/// through `NSRunningApplication` for a real name/bundle ID; background
/// daemons (nettop reports these too — e.g. softwareupdated) fall back to
/// their executable name, keyed so relaunches under a new pid still
/// aggregate into the same row.
enum ProcessDirectory {
    struct Identity {
        let id: String
        let name: String
        let bundleID: String
        let statusHint: String
    }

    static func identify(pid: Int32, fallbackCommand: String) -> Identity {
        if let app = NSRunningApplication(processIdentifier: pid) {
            let bundleID = app.bundleIdentifier ?? "pid.\(pid)"
            let name = app.localizedName ?? fallbackCommand
            return Identity(id: bundleID, name: name, bundleID: bundleID, statusHint: "运行中")
        }
        let cleaned = fallbackCommand.isEmpty ? "pid-\(pid)" : fallbackCommand
        let key = "proc." + cleaned
        return Identity(id: key, name: cleaned, bundleID: key, statusHint: "后台进程")
    }
}
