import Foundation
import Security

/// The certificate authority the upload inspector signs its per-site
/// certificates with, so an app that trusts it lets NetPulse read what it
/// sends over HTTPS.
///
/// Made on this Mac the first time the inspector starts, with the system's
/// own `/usr/bin/openssl`; its key never leaves
/// `~/Library/Application Support/NetPulse/inspector` (a 0700 directory).
/// Nothing trusts it until the user points an app at `ca.pem` or adds it
/// to their keychain, and deleting the directory retires it.
final class InspectorCA {
    static let commonName = "NetPulse Upload Inspector"

    let directory: URL
    var certificatePEM: URL { directory.appendingPathComponent("ca.pem") }
    /// The system's roots plus this CA, for tools whose CA setting replaces
    /// their trust store rather than adding to it (`SSL_CERT_FILE`).
    var bundlePEM: URL { directory.appendingPathComponent("ca-bundle.pem") }
    private var caKey: URL { directory.appendingPathComponent("ca.key") }
    private var leafKey: URL { directory.appendingPathComponent("leaf.key") }
    private var leafKeyDER: URL { directory.appendingPathComponent("leaf.key.der") }
    private var hostsDirectory: URL { directory.appendingPathComponent("hosts", isDirectory: true) }

    private let lock = NSLock()
    private var identities: [String: SecIdentity] = [:]
    private var privateKey: SecKey?

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NetPulse/inspector", isDirectory: true)) {
        self.directory = directory
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var exists: Bool { FileManager.default.fileExists(atPath: certificatePEM.path) }

    /// Creates the CA and the key every site certificate shares, once.
    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: hostsDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !fm.fileExists(atPath: caKey.path) || !fm.fileExists(atPath: certificatePEM.path) {
            let config = directory.appendingPathComponent("ca.cnf")
            try """
            [req]
            distinguished_name = dn
            prompt = no
            [dn]
            CN = \(Self.commonName)
            O = NetPulse
            [ca_ext]
            basicConstraints = critical,CA:TRUE
            keyUsage = critical,keyCertSign,cRLSign
            subjectKeyIdentifier = hash
            """.write(to: config, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: config) }
            try openssl(["genrsa", "-out", caKey.path, "2048"])
            try openssl(["req", "-x509", "-new", "-key", caKey.path, "-sha256", "-days", "3650",
                         "-config", config.path, "-extensions", "ca_ext", "-out", certificatePEM.path])
            // Certificates signed by an older CA are no good any more.
            try? fm.removeItem(at: hostsDirectory)
            try fm.createDirectory(at: hostsDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try? fm.removeItem(at: bundlePEM)
        }
        if !fm.fileExists(atPath: leafKeyDER.path) {
            try openssl(["genrsa", "-out", leafKey.path, "2048"])
            try openssl(["rsa", "-in", leafKey.path, "-outform", "DER", "-out", leafKeyDER.path])
        }
        for file in [caKey, leafKey, leafKeyDER] {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if !fm.fileExists(atPath: bundlePEM.path) {
            let roots = (try? run("/usr/bin/security", ["find-certificate", "-a", "-p",
                                                       "/System/Library/Keychains/SystemRootCertificates.keychain"])) ?? Data()
            var bundle = roots
            bundle.append(try Data(contentsOf: certificatePEM))
            try bundle.write(to: bundlePEM, options: .atomic)
        }
        if privateKey == nil {
            let der = try Data(contentsOf: leafKeyDER)
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
                throw Failure(message: "无法读取证书私钥：\(error?.takeRetainedValue().localizedDescription ?? "未知错误")")
            }
            privateKey = key
        }
    }

    /// The identity to present for `host`, signing a certificate for it the
    /// first time it is asked for.
    func identity(for host: String) throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let known = identities[host] { return known }
        guard let privateKey else { throw Failure(message: "证书尚未准备好") }
        let der = try certificate(for: host)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw Failure(message: "无法读取 \(host) 的证书")
        }
        guard let make = secIdentityCreate,
              let identity = make(kCFAllocatorDefault, certificate, privateKey)?.takeRetainedValue() else {
            throw Failure(message: "系统不支持在内存中组装证书身份")
        }
        identities[host] = identity
        return identity
    }

    private func certificate(for host: String) throws -> Data {
        let safe = host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        let der = hostsDirectory.appendingPathComponent(safe + ".der")
        if let data = try? Data(contentsOf: der) { return data }
        let isIP = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        let csr = hostsDirectory.appendingPathComponent(safe + ".csr")
        let ext = hostsDirectory.appendingPathComponent(safe + ".cnf")
        defer {
            try? FileManager.default.removeItem(at: csr)
            try? FileManager.default.removeItem(at: ext)
        }
        try """
        [leaf]
        basicConstraints = CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(isIP ? "IP" : "DNS"):\(host)
        authorityKeyIdentifier = keyid
        """.write(to: ext, atomically: true, encoding: .utf8)
        // Clients go by the subjectAltName; the CN only has to be valid,
        // and may be at most 64 characters.
        let cn = host.count <= 64 ? host : "netpulse-inspected-site"
        try openssl(["req", "-new", "-key", leafKey.path, "-subj", "/CN=\(cn)", "-out", csr.path])
        // Apple rejects server certificates valid for more than 398 days.
        try openssl(["x509", "-req", "-in", csr.path, "-CA", certificatePEM.path, "-CAkey", caKey.path,
                     "-set_serial", String(UInt64.random(in: 1...UInt64(Int64.max))), "-days", "397", "-sha256",
                     "-extfile", ext.path, "-extensions", "leaf", "-outform", "DER", "-out", der.path])
        return try Data(contentsOf: der)
    }

    // MARK: - Keychain trust

    /// Marks the CA trusted for this user, which apps that use the system's
    /// trust store (Safari, most native and Rust tools) need. macOS asks for
    /// the user's password itself. Returns an error message, or nil.
    func trustInKeychain() -> String? {
        let keychain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path
        do {
            try run("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain, certificatePEM.path])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeKeychainTrust() -> String? {
        do {
            try run("/usr/bin/security", ["remove-trusted-cert", certificatePEM.path])
            _ = try? run("/usr/bin/security", ["delete-certificate", "-c", Self.commonName])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Running tools

    @discardableResult
    private func openssl(_ arguments: [String]) throws -> Data {
        try run("/usr/bin/openssl", arguments)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read both before waiting: a full pipe would stall the tool.
        var errData = Data()
        let errRead = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errRead.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errRead.wait()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "\((tool as NSString).lastPathComponent) \(arguments.first ?? "") 失败：\(detail.isEmpty ? "退出码 \(process.terminationStatus)" : String(detail.prefix(300)))")
        }
        return outData
    }
}

/// `SecIdentityCreate` pairs a certificate with a key held in memory. It is
/// exported by Security.framework but not in its headers; the public routes
/// to an identity all go through a keychain, which would leave a
/// certificate per site behind in the user's login keychain.
private typealias SecIdentityCreateFunction = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?

private let secIdentityCreate: SecIdentityCreateFunction? = {
    // RTLD_DEFAULT
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecIdentityCreate") else { return nil }
    return unsafeBitCast(symbol, to: SecIdentityCreateFunction.self)
}()
