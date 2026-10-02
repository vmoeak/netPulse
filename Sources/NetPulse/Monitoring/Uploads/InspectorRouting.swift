import AppKit
import Darwin
import Security

/// Points one app at the inspector without touching the system proxy: the
/// app is quit and opened again with Chromium's `--proxy-server` flag (which
/// Chrome, Edge and every Electron app honor) and the proxy and CA in its
/// environment (for Node and other runtimes inside it). Turning it off opens
/// the app again plainly. Native apps that only follow the system proxy
/// ignore both and keep connecting directly.
enum InspectorRouting {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func proxyArgument(port: UInt16) -> String {
        "--proxy-server=http://127.0.0.1:\(port)"
    }

    static func environment(port: UInt16, ca: InspectorCA) -> [String: String] {
        let proxy = "http://127.0.0.1:\(port)"
        return [
            "HTTPS_PROXY": proxy, "HTTP_PROXY": proxy, "https_proxy": proxy, "http_proxy": proxy,
            "NODE_EXTRA_CA_CERTS": ca.certificatePEM.path,
            "SSL_CERT_FILE": ca.bundlePEM.path, "REQUESTS_CA_BUNDLE": ca.bundlePEM.path,
        ]
    }

    /// The running instance of an app with a bundle; nil for bare processes,
    /// which can't be relaunched from here.
    static func runningApp(bundleID: String) -> NSRunningApplication? {
        guard !bundleID.hasPrefix("proc.") else { return nil }
        // Newest live instance: right after a relaunch the old one can still
        // be listed for a moment.
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { kill($0.processIdentifier, 0) == 0 }
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
    }

    static func canRelaunch(bundleID: String) -> Bool {
        guard !bundleID.hasPrefix("proc.") else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Whether the app's running instance was opened through the inspector,
    /// read from its launch arguments, so it survives NetPulse restarting.
    static func isRouted(bundleID: String, port: UInt16) -> Bool {
        guard let app = runningApp(bundleID: bundleID) else { return false }
        return arguments(of: app.processIdentifier).contains(proxyArgument(port: port))
    }

    /// Every running app opened through the inspector on `port`.
    static func routedApps(port: UInt16) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier != nil && arguments(of: $0.processIdentifier).contains(proxyArgument(port: port))
        }
    }

    /// Quits the app (if running) and opens it again, through the proxy on
    /// `port`, or plainly when `port` is nil.
    @MainActor
    static func relaunch(bundleID: String, through port: UInt16?, ca: InspectorCA) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw Failure(message: "找不到这个 App 的安装位置")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        // `isTerminated` follows workspace notifications and can lag; the
        // pid answering signal 0 is the ground truth.
        let pids = running.map(\.processIdentifier)
        func anyAlive() -> Bool { pids.contains { kill($0, 0) == 0 } }
        for app in running { app.terminate() }
        // Apps may ask to save first; give them a while. Some (Noi, apps that
        // live in the menu bar) ignore a polite quit altogether, so after
        // that they are force-quit — the user already agreed to the restart.
        for _ in 0..<80 where anyAlive() {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        for app in running where kill(app.processIdentifier, 0) == 0 { app.forceTerminate() }
        for _ in 0..<50 where anyAlive() {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if anyAlive() {
            throw Failure(message: "App 没有退出，手动退出后再试")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let port {
            configuration.arguments = [proxyArgument(port: port)]
            configuration.environment = environment(port: port, ca: ca)
        }
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The process's argv, from `KERN_PROCARGS2`: argc, the executable
    /// path, padding, then the arguments, all NUL-separated.
    static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Executable path, then NULs up to argv[0].
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while index < size, result.count < argc {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}

extension InspectorCA {
    /// Whether the user's trust settings already mark this CA trusted.
    var isTrustedInKeychain: Bool {
        guard let pem = try? String(contentsOf: certificatePEM, encoding: .utf8) else { return false }
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return false }
        var settings: CFArray?
        return SecTrustSettingsCopyTrustSettings(certificate, .user, &settings) == errSecSuccess
    }
}
