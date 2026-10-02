import Foundation

/// A kind of local information an upload can carry. Everything but
/// `localPath` comes from git: what code agents have been caught sending
/// is their user's repository state, remotes and identity.
enum UploadFindingKind: String, CaseIterable, Identifiable {
    case gitRemote, gitStatus, gitCommit, gitIdentity, gitFiles, localPath

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gitRemote: return "Git 远程地址"
        case .gitStatus: return "Git 分支/状态"
        case .gitCommit: return "提交记录"
        case .gitIdentity: return "Git 身份"
        case .gitFiles: return ".git 内容"
        case .localPath: return "本机路径"
        }
    }

    var isGit: Bool { self != .localPath }
}

/// Where in a text one kind of information appeared.
struct UploadMatch: Equatable {
    var kind: UploadFindingKind
    var range: NSRange
}

/// One kind of information found in a request, with what matched.
struct UploadFinding: Equatable, Identifiable {
    var id: String { kind.rawValue }
    var kind: UploadFindingKind
    /// Distinct matched strings, most frequent first (at most a handful).
    var samples: [String]
    var count: Int
}

/// The user's own git name and email, from their global git config, so an
/// upload that carries them can be named as such.
struct GitIdentity: Equatable {
    var names: [String] = []
    var emails: [String] = []

    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> GitIdentity {
        var identity = GitIdentity()
        for path in [".gitconfig", ".config/git/config"] {
            guard let text = try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) else { continue }
            identity.merge(parse(config: text))
        }
        return identity
    }

    /// `name`/`email` under `[user]` (git config's own format: sections in
    /// brackets, `key = value`, `#`/`;` comments, optional quotes).
    static func parse(config text: String) -> GitIdentity {
        var identity = GitIdentity()
        var inUser = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inUser = line.lowercased().hasPrefix("[user]")
                continue
            }
            guard inUser, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let comment = value.firstIndex(where: { $0 == "#" || $0 == ";" }), !value.hasPrefix("\"") {
                value = value[..<comment].trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !value.isEmpty else { continue }
            if key == "name" { identity.names.append(value) }
            if key == "email" { identity.emails.append(value) }
        }
        return identity
    }

    mutating func merge(_ other: GitIdentity) {
        for name in other.names where !names.contains(name) { names.append(name) }
        for email in other.emails where !emails.contains(email) { emails.append(email) }
    }
}

/// Finds git information (and paths on this Mac) in what an app uploads.
///
/// The patterns aim at what agents actually embed: Claude Code's prompt
/// carries a `gitStatus:` block with the branch, `git status` output and
/// recent commits; others send remote URLs, `.git/config` contents or the
/// author's name and email. Inside a JSON body newlines are the two
/// characters `\n` and quotes are `\"`, so the patterns accept both forms.
struct UploadScanner {
    var identity: GitIdentity
    var homeDirectory: String

    init(identity: GitIdentity = .load(), homeDirectory: String = NSHomeDirectory()) {
        self.identity = identity
        self.homeDirectory = homeDirectory
        patterns = Self.basePatterns + Self.personalPatterns(identity: identity, home: homeDirectory)
    }

    private let patterns: [(UploadFindingKind, NSRegularExpression)]

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static let basePatterns: [(UploadFindingKind, NSRegularExpression)] = {
        let list: [(UploadFindingKind, String)] = [
            // git@github.com:owner/repo.git, ssh://git@host/owner/repo
            (.gitRemote, #"(?:ssh://)?git@[A-Za-z0-9.-]+[:/][A-Za-z0-9._~-]+/[A-Za-z0-9._~/-]*[A-Za-z0-9_~-]"#),
            // https://host/owner/repo.git
            (.gitRemote, #"https?://[A-Za-z0-9.@:%_-]+/[A-Za-z0-9._~/-]+\.git(?![A-Za-z0-9])"#),
            (.gitStatus, [
                #"gitStatus"#, #"Is directory a git repo"#, #"Current branch:[^\\\n"]*"#,
                #"Main branch[^\\\n"]*"#, #"Recent commits:"#, #"On branch [^\s\\"]+"#,
                #"Your branch is (?:up to date|ahead|behind)[^\\\n"]*"#,
                #"Changes not staged for commit"#, #"Changes to be committed"#, #"Untracked files:"#,
                #"nothing to commit, working tree clean"#, #"HEAD -> [^\s\\",)]+"#,
                #"refs/heads/[A-Za-z0-9._/-]+"#,
            ].joined(separator: "|")),
            (.gitCommit, #"\bcommit [0-9a-f]{40}\b"#),
            // `git log --oneline`: a short hash (with at least one digit, so
            // a word like "acceded" isn't one) opening a line.
            (.gitCommit, #"(?m)(?<=^|\\n)(?=[0-9a-f]*[0-9])[0-9a-f]{7,12}(?= \S)"#),
            (.gitIdentity, #"Author: [^<\n\\]{1,80}<[^>\s@]+@[^>\s]+>"#),
            (.gitFiles, #"\.git/(?:config|HEAD|index|COMMIT_EDITMSG|ORIG_HEAD|FETCH_HEAD|packed-refs|refs/[A-Za-z0-9._/-]*|logs/[A-Za-z0-9._/-]*)"#),
            (.gitFiles, #"\[(?:remote|branch) \\?"[^"\\]+\\?"\]"#),
        ]
        return list.compactMap { kind, pattern in regex(pattern).map { (kind, $0) } }
    }()

    private static func personalPatterns(identity: GitIdentity, home: String) -> [(UploadFindingKind, NSRegularExpression)] {
        var list: [(UploadFindingKind, NSRegularExpression)] = []
        for email in identity.emails {
            if let r = regex(NSRegularExpression.escapedPattern(for: email), caseInsensitive: true) { list.append((.gitIdentity, r)) }
        }
        // A one-letter name would match everywhere.
        for name in identity.names where name.count >= 2 {
            if let r = regex(NSRegularExpression.escapedPattern(for: name)) { list.append((.gitIdentity, r)) }
        }
        // "/Users/me" alone, or down to the file: it names the user and,
        // further down, their projects.
        if home.count > 1, let r = regex(NSRegularExpression.escapedPattern(for: home) + #"(?![A-Za-z0-9._-])(?:/[^\s"'\\<>()\[\],;:]*)?"#) {
            list.append((.localPath, r))
        }
        return list
    }

    /// Every match, in text order, for highlighting.
    func matches(in text: String) -> [UploadMatch] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        var found: [UploadMatch] = []
        for (kind, regex) in patterns {
            for result in regex.matches(in: text, options: [], range: whole) where result.range.length > 0 {
                found.append(UploadMatch(kind: kind, range: result.range))
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The matches folded by kind, git kinds first.
    static func findings(from matches: [UploadMatch], in text: String) -> [UploadFinding] {
        let ns = text as NSString
        var byKind: [UploadFindingKind: [String: Int]] = [:]
        for match in matches {
            let sample = String(ns.substring(with: match.range).prefix(160))
            byKind[match.kind, default: [:]][sample, default: 0] += 1
        }
        return UploadFindingKind.allCases.compactMap { kind in
            guard let samples = byKind[kind] else { return nil }
            let ranked = samples.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            return UploadFinding(kind: kind, samples: ranked.prefix(6).map(\.key),
                                 count: samples.values.reduce(0, +))
        }
    }
}

/// Turns a request body into text a person can read: decompressed, JSON
/// pretty-printed, forms decoded.
enum UploadBodyText {
    static func render(body: Data, contentType: String?, contentEncoding: String?) -> (text: String, note: String?) {
        guard !body.isEmpty else { return ("", nil) }
        var data = body
        var notes: [String] = []
        let encoding = contentEncoding?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        if !encoding.isEmpty, encoding != "identity" {
            if let decoded = decompress(body, encoding: encoding) {
                data = decoded
                notes.append("已解压（\(encoding)）")
            } else {
                notes.append("以 \(encoding) 压缩，无法解压，下面是原始字节")
            }
        }
        let type = contentType?.lowercased() ?? ""
        let looksJSON = type.contains("json") || data.first.map({ $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") }) == true
        if looksJSON, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]),
           let text = String(data: pretty, encoding: .utf8) {
            return (text, notes.isEmpty ? nil : notes.joined(separator: " · "))
        }
        if let text = String(data: data, encoding: .utf8) {
            if type.contains("x-www-form-urlencoded") {
                let decoded = text.split(separator: "&").map { pair -> String in
                    let plain = pair.replacingOccurrences(of: "+", with: " ")
                    return plain.removingPercentEncoding ?? plain
                }.joined(separator: "\n")
                return (decoded, (notes + ["表单已逐项解码"]).joined(separator: " · "))
            }
            return (text, notes.isEmpty ? nil : notes.joined(separator: " · "))
        }
        // Protobuf and other binary bodies still carry their strings as
        // UTF-8, which is what matters for spotting git data.
        notes.append("非文本内容，按 UTF-8 尽量显示")
        let lossy = String(decoding: data, as: UTF8.self).map { ch -> Character in
            ch.isASCII && (ch.asciiValue ?? 0) < 0x20 && ch != "\n" && ch != "\t" ? "·" : ch
        }
        return (String(lossy), notes.joined(separator: " · "))
    }

    static func decompress(_ data: Data, encoding: String) -> Data? {
        let bytes = [UInt8](data)
        switch encoding {
        case "gzip", "x-gzip": return gunzip(bytes)
        case "deflate": return inflate(bytes)
        default: return nil
        }
    }

    /// RFC 1952: a header (with optional fields), raw DEFLATE, then an
    /// 8-byte CRC and size trailer.
    static func gunzip(_ d: [UInt8]) -> Data? {
        guard d.count > 18, d[0] == 0x1f, d[1] == 0x8b, d[2] == 8 else { return nil }
        let flags = d[3]
        var i = 10
        if flags & 0x04 != 0 {
            guard d.count > i + 2 else { return nil }
            i += 2 + (Int(d[i]) | Int(d[i + 1]) << 8)
        }
        for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {
            while i < d.count, d[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }
        guard i < d.count - 8 else { return nil }
        return rawInflate(Data(d[i..<(d.count - 8)]))
    }

    /// HTTP's "deflate" is zlib-wrapped, though some senders send it raw.
    static func inflate(_ d: [UInt8]) -> Data? {
        if d.count > 6, d[0] & 0x0f == 8, (Int(d[0]) << 8 | Int(d[1])) % 31 == 0 {
            return rawInflate(Data(d[2..<(d.count - 4)]))
        }
        return rawInflate(Data(d))
    }

    /// NSData's `.zlib` is raw DEFLATE (RFC 1951), without either wrapper.
    private static func rawInflate(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .zlib) as Data
    }
}
