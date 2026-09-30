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
        let cleaned = processName(pid: pid, command: fallbackCommand)
        let key = "proc." + cleaned
        return Identity(id: key, name: cleaned, bundleID: key, statusHint: "后台进程")
    }

    /// The executable's file name when the path is readable, which is both
    /// untruncated (nettop cuts names at 15 characters) and free of
    /// arguments. The reported command can't be trusted for that: a process
    /// may retitle itself with its whole command line — `npm exec` does,
    /// secrets in its flags included — and the name becomes the row's id,
    /// shown on screen and saved to history on disk.
    static func processName(pid: Int32, command: String) -> String {
        if let path = executablePath(of: pid) {
            let base = (path as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        return sanitizedCommand(command, pid: pid)
    }

    /// Without a path, a name that looks like a command line is cut to its
    /// program name, so a retitled process can't carry its arguments along —
    /// flags or not (`npm exec pkg <token>` has none).
    static func sanitizedCommand(_ command: String, pid: Int32) -> String {
        var name = command.trimmingCharacters(in: .whitespaces)
        if looksLikeCommandLine(name) {
            let program = name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            name = (program as NSString).lastPathComponent
        }
        name = String(name.prefix(40))
        return name.isEmpty ? "pid-\(pid)" : name
    }

    /// Process names are short words ("Google Chrome H", "mDNSResponder");
    /// paths, flags, `key=value`, `@scope/pkg` or great length mean the
    /// process retitled itself with its arguments.
    static func looksLikeCommandLine(_ name: String) -> Bool {
        name.count > 40 || name.contains(" -") || name.contains(where: { "/=@".contains($0) })
    }

    private static func identity(for app: NSRunningApplication, statusHint: String) -> Identity {
        let pid = app.processIdentifier
        guard let bundleID = app.bundleIdentifier else {
            // No bundle: a plain executable macOS still lists as an app (an
            // `npm exec` node process is one). Its localizedName is the
            // process title, which can be the whole command line with its
            // secrets, so it is named by executable like any process.
            let cleaned = processName(pid: pid, command: app.localizedName ?? "")
            let key = "proc." + cleaned
            return Identity(id: key, name: cleaned, bundleID: key, statusHint: statusHint)
        }
        let name = (app.bundleURL.flatMap(preferredDisplayName(ofBundleAt:)) ?? app.localizedName)
            .map { sanitizedCommand($0, pid: pid) } ?? bundleID
        return Identity(id: bundleID, name: name, bundleID: bundleID, statusHint: statusHint)
    }

    /// The app's name in the user's language. `localizedName` picks the
    /// localization that matches NetPulse's own, so an app with a Chinese
    /// name (QQ 电脑管家's helper, 「办公安全感知」) showed its English one.
    static func preferredDisplayName(ofBundleAt url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        let localizations = bundle.localizations.filter { $0 != "Base" }
        for localization in Bundle.preferredLocalizations(from: localizations, forPreferences: Locale.preferredLanguages) {
            guard let path = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil,
                                         forLocalization: localization),
                  let strings = NSDictionary(contentsOfFile: path) as? [String: String] else { continue }
            if let name = strings["CFBundleDisplayName"] ?? strings["CFBundleName"], !name.isEmpty { return name }
        }
        return nil
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
