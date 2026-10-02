import AppKit

/// One request an app sent through the inspector, ready to show.
struct CapturedUpload: Identifiable {
    var id = 0
    let date: Date
    let processName: String
    let pid: Int32?
    let scheme: String
    let host: String
    let port: Int
    let method: String
    /// Path and query.
    let path: String
    let headers: [HeaderField]
    let bodySize: Int
    let bodyTruncated: Bool
    let rawBody: Data
    /// The body as text (decompressed, JSON pretty-printed).
    let bodyText: String
    let bodyNote: String?
    /// Where in `bodyText` the scanner found something.
    let bodyMatches: [UploadMatch]
    /// Everything found, in the URL and headers as well as the body.
    let findings: [UploadFinding]
    /// Set when the app's connection couldn't be read at all.
    let failure: String?

    var hasGit: Bool { findings.contains { $0.kind.isGit } }
    var gitMatchCount: Int { findings.filter(\.kind.isGit).reduce(0) { $0 + $1.count } }
    var userAgent: String? { headers.first { $0.name.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value }

    var url: String {
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host)\(port == defaultPort ? "" : ":\(port)")\(path)"
    }

    /// Authorization and cookie values are the app's credentials, not
    /// something it reveals about the user; they are shown cut down.
    static let secretHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "x-api-key", "api-key",
        "x-goog-api-key", "openai-api-key", "anthropic-api-key", "x-auth-token",
    ]

    static func displayValue(of header: HeaderField) -> String {
        guard secretHeaders.contains(header.name.lowercased()) else { return header.value }
        let value = header.value
        guard value.count > 16 else { return String(repeating: "•", count: min(8, value.count)) }
        return "\(value.prefix(10))…\(value.suffix(4))（已隐藏 \(value.count - 14) 个字符）"
    }

    static func make(from event: InspectorEvent, scanner: UploadScanner) -> CapturedUpload {
        guard let request = event.request else {
            return CapturedUpload(date: event.date, processName: event.processName, pid: event.pid, scheme: event.scheme,
                                  host: event.host, port: event.port, method: "CONNECT", path: "", headers: [],
                                  bodySize: 0, bodyTruncated: false, rawBody: Data(), bodyText: "", bodyNote: nil,
                                  bodyMatches: [], findings: [], failure: event.failure)
        }
        var path = request.target
        if let url = URL(string: path), url.scheme != nil {
            // Absolute form, from a plain-HTTP proxy request.
            let query = url.query.map { "?" + $0 } ?? ""
            path = (url.path.isEmpty ? "/" : url.path) + query
        }
        let rendered = UploadBodyText.render(body: request.body, contentType: request.header("Content-Type"),
                                             contentEncoding: request.header("Content-Encoding"))
        let bodyMatches = scanner.matches(in: rendered.text)
        // The URL and headers are scanned too (a repo can ride in a query
        // string or a custom header), but only the body is highlighted.
        let headerText = ([path] + request.headers.map { "\($0.name): \($0.value)" }).joined(separator: "\n")
        let headerMatches = scanner.matches(in: headerText)
        var findings = UploadScanner.findings(from: bodyMatches, in: rendered.text)
        for extra in UploadScanner.findings(from: headerMatches, in: headerText) {
            if let i = findings.firstIndex(where: { $0.kind == extra.kind }) {
                findings[i].count += extra.count
                for sample in extra.samples where !findings[i].samples.contains(sample) { findings[i].samples.append(sample) }
            } else {
                findings.append(extra)
            }
        }
        findings.sort { UploadFindingKind.allCases.firstIndex(of: $0.kind)! < UploadFindingKind.allCases.firstIndex(of: $1.kind)! }
        var note = rendered.note
        if request.bodyTruncated {
            let cut = "只保留了前 \(Format.bytes(request.body.count))，共 \(Format.bytes(request.bodySize))"
            note = note.map { $0 + " · " + cut } ?? cut
        }
        return CapturedUpload(date: event.date, processName: event.processName, pid: event.pid, scheme: event.scheme,
                              host: event.host, port: event.port, method: request.method, path: path,
                              headers: request.headers, bodySize: request.bodySize, bodyTruncated: request.bodyTruncated,
                              rawBody: request.body, bodyText: rendered.text, bodyNote: note,
                              bodyMatches: bodyMatches, findings: findings, failure: nil)
    }

    /// The request as text, for 导出.
    var exportText: String {
        var lines = ["\(method) \(url)", "时间: \(date)", "进程: \(processName)\(pid.map { " (pid \($0))" } ?? "")", ""]
        lines += headers.map { "\($0.name): \(Self.displayValue(of: $0))" }
        lines.append("")
        if !findings.isEmpty {
            lines.append("# 发现")
            for finding in findings {
                lines.append("- \(finding.kind.label) ×\(finding.count): \(finding.samples.joined(separator: " | "))")
            }
            lines.append("")
        }
        lines.append(bodyText)
        return lines.joined(separator: "\n")
    }
}

/// 上传检查: runs the inspecting proxy and keeps what apps sent through it,
/// in memory only (500 requests at most). Off until the user turns it on.
@MainActor
final class UploadInspector: ObservableObject {
    enum State: Equatable {
        case off
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// Newest first.
    @Published private(set) var uploads: [CapturedUpload] = []
    @Published var selectedID: Int?
    @Published var gitOnly = false
    @Published private(set) var trustMessage: String?

    static let preferredPort: UInt16 = 9696
    static let maxUploads = 500
    static let maxStoredBytes = 256 << 20
    private static let enabledKey = "uploadInspectorEnabled"

    let ca: InspectorCA
    private let proxy: InspectorProxy
    private let defaults: UserDefaults
    private let scanQueue = DispatchQueue(label: "NetPulse.inspector.scan", qos: .utility)
    private var nextID = 1

    init(ca: InspectorCA = InspectorCA(), defaults: UserDefaults = .standard) {
        self.ca = ca
        self.defaults = defaults
        proxy = InspectorProxy(ca: ca)
    }

    /// Whether the user left it on last time.
    var wasEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var visibleUploads: [CapturedUpload] { gitOnly ? uploads.filter(\.hasGit) : uploads }

    var selectedUpload: CapturedUpload? {
        uploads.first { $0.id == selectedID }
    }

    /// `remember` keeps it on across launches; the self-test doesn't.
    func start(remember: Bool = true) {
        switch state {
        case .running, .starting: return
        case .off, .failed: break
        }
        if remember { defaults.set(true, forKey: Self.enabledKey) }
        state = .starting
        let queue = scanQueue
        // The scanner reads the user's git config; built once per start so
        // a changed identity is picked up next time.
        let scanner = UploadScanner()
        proxy.onEvent = { [weak self] event in
            queue.async {
                let upload = CapturedUpload.make(from: event, scanner: scanner)
                Task { @MainActor in self?.append(upload) }
            }
        }
        let ca = self.ca, proxy = self.proxy, port = Self.preferredPort
        DispatchQueue.global(qos: .userInitiated).async {
            let result: State
            do {
                try ca.prepare()
                result = .running(port: try proxy.start(preferred: port))
            } catch {
                result = .failed(error.localizedDescription)
            }
            Task { @MainActor in self.state = result }
        }
    }

    func stop(remember: Bool = true) {
        proxy.stop()
        if remember { defaults.set(false, forKey: Self.enabledKey) }
        state = .off
    }

    func clear() {
        uploads = []
        selectedID = nil
    }

    func trustCertificate() {
        trustMessage = "正在等待 macOS 确认…"
        let ca = self.ca
        DispatchQueue.global(qos: .userInitiated).async {
            let error = ca.trustInKeychain()
            Task { @MainActor in
                self.trustMessage = error.map { "未能加入信任：\($0)" } ?? "已在钥匙串中信任 NetPulse 证书"
            }
        }
    }

    func untrustCertificate() {
        let ca = self.ca
        DispatchQueue.global(qos: .userInitiated).async {
            let error = ca.removeKeychainTrust()
            Task { @MainActor in
                self.trustMessage = error.map { "未能取消信任：\($0)" } ?? "已从钥匙串移除 NetPulse 证书"
            }
        }
    }

    private func append(_ upload: CapturedUpload) {
        var upload = upload
        upload.id = nextID
        nextID += 1
        uploads.insert(upload, at: 0)
        if uploads.count > Self.maxUploads { uploads.removeLast(uploads.count - Self.maxUploads) }
        var stored = uploads.reduce(0) { $0 + $1.rawBody.count + $1.bodyText.utf8.count }
        while stored > Self.maxStoredBytes, uploads.count > 1 {
            let dropped = uploads.removeLast()
            stored -= dropped.rawBody.count + dropped.bodyText.utf8.count
        }
        if selectedID == nil || !uploads.contains(where: { $0.id == selectedID }) { selectedID = upload.id }
    }

    /// Shell lines that send a command-line tool's traffic through the
    /// inspector: the proxy, plus the CA for each runtime's own setting.
    func shellSetup(port: UInt16) -> String {
        let proxy = "http://127.0.0.1:\(port)"
        func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        export HTTPS_PROXY=\(proxy) HTTP_PROXY=\(proxy) https_proxy=\(proxy) http_proxy=\(proxy)
        export NODE_EXTRA_CA_CERTS=\(quoted(ca.certificatePEM))
        export SSL_CERT_FILE=\(quoted(ca.bundlePEM)) REQUESTS_CA_BUNDLE=\(quoted(ca.bundlePEM)) GIT_SSL_CAINFO=\(quoted(ca.bundlePEM))
        """
    }

    var selfTestState: String {
        switch state {
        case .off: return "off"
        case .starting: return "starting"
        case .running(let port): return "running:\(port)"
        case .failed(let message): return "failed: \(message)"
        }
    }

    var selfTestRows: [[String: Any]] {
        uploads.map { upload in
            [
                "process": upload.processName,
                "method": upload.method,
                "host": upload.host,
                "path": upload.path,
                "bodySize": upload.bodySize,
                "findings": upload.findings.map(\.kind.rawValue),
                "failure": upload.failure ?? "",
            ]
        }
    }
}
