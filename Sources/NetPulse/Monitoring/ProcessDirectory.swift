import AppKit
import Darwin

/// Resolves a pid (from nettop) to a stable app identity. GUI apps go
/// through `NSRunningApplication` for a real name/bundle ID; background
/// daemons (nettop reports these too — e.g. softwareupdated) fall back to
/// their executable name, keyed so relaunches under a new pid still
/// aggregate into the same row.
///
/// Browsers and Electron apps do their networking in helper processes —
/// Chrome's own window process holds barely a socket, and on a live Mac
/// nettop reports its traffic entirely under `Google Chrome H.<pid>`. Taken
/// verbatim that shows Chrome at zero while the bytes sit under a truncated
/// row nobody recognizes, so `owningApplication(of:)` folds a helper into
/// the app that owns it.
enum ProcessDirectory {
    struct Identity {
        let id: String
        let name: String
        let bundleID: String
        let statusHint: String
    }

    static func identify(pid: Int32, fallbackCommand: String) -> Identity {
        // The owning app is asked about first on purpose. Chrome's helpers are
        // themselves .app bundles with their own bundle ID, so asking about
        // the pid directly resolves to "Google Chrome Helper" and would never
        // reach Chrome. A top-level app has no ancestor holding its
        // executable (its parent is launchd), so it still identifies as
        // itself.
        if let owner = owningApplication(of: pid) {
            return identity(for: owner, statusHint: "运行中")
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            return identity(for: app, statusHint: "运行中")
        }
        let cleaned = fallbackCommand.isEmpty ? "pid-\(pid)" : fallbackCommand
        let key = "proc." + cleaned
        return Identity(id: key, name: cleaned, bundleID: key, statusHint: "后台进程")
    }

    private static func identity(for app: NSRunningApplication, statusHint: String) -> Identity {
        let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        let name = app.localizedName ?? bundleID
        return Identity(id: bundleID, name: name, bundleID: bundleID, statusHint: statusHint)
    }

    /// Walks up from `pid` looking for an ancestor that is a real application
    /// *and* whose bundle contains this process's executable.
    ///
    /// The containment test is what keeps this from over-grouping: a Chrome
    /// helper lives inside `Google Chrome.app`, so it folds in, while a
    /// `curl` a user ran in Terminal lives in `/usr/bin` and keeps its own
    /// row rather than being reported as Terminal's traffic.
    private static func owningApplication(of pid: Int32) -> NSRunningApplication? {
        guard let path = executablePath(of: pid) else { return nil }
        var current = pid
        // Helpers sit one or two levels under their app; the bound just stops
        // this from walking a deep daemon tree every time it resolves a pid.
        for _ in 0..<4 {
            guard let parent = parentPID(of: current) else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent),
               let bundlePath = app.bundleURL?.path,
               path.hasPrefix(bundlePath + "/") {
                return app
            }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let ok = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0) == 0
        }
        guard ok, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        // Stop at launchd: everything descends from it, so it owns nothing.
        return ppid > 1 ? ppid : nil
    }

    private static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
