import XCTest
@testable import NetPulse

final class UploadInspectorTests: XCTestCase {
    // MARK: - HTTP parsing

    func testRequestSplitAcrossReads() {
        var parser = HTTPRequestParser()
        let raw = Array("POST /v1/messages HTTP/1.1\r\nHost: api.example.com\r\nContent-Length: 11\r\n\r\nhello world".utf8)
        XCTAssertEqual(parser.feed(Array(raw[0..<20])), [])
        XCTAssertEqual(parser.feed(Array(raw[20..<70])), [])
        let done = parser.feed(Array(raw[70...]))
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.method, "POST")
        XCTAssertEqual(done.first?.target, "/v1/messages")
        XCTAssertEqual(done.first?.header("host"), "api.example.com")
        XCTAssertEqual(done.first.map { String(decoding: $0.body, as: UTF8.self) }, "hello world")
    }

    func testKeepAliveAndChunkedBodies() {
        var parser = HTTPRequestParser()
        let raw = "GET /a HTTP/1.1\r\nHost: x\r\n\r\n"
            + "POST /b HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: y\r\n\r\n"
            + "PUT /c HTTP/1.1\r\nContent-Length: 2\r\n\r\nok"
        let done = parser.feed(Array(raw.utf8))
        XCTAssertEqual(done.map(\.target), ["/a", "/b", "/c"])
        XCTAssertEqual(String(decoding: done[1].body, as: UTF8.self), "hello world")
        XCTAssertEqual(done[1].bodySize, 11)
        XCTAssertEqual(String(decoding: done[2].body, as: UTF8.self), "ok")
    }

    func testLongBodyIsCutButCounted() {
        var parser = HTTPRequestParser(maxBody: 4)
        let done = parser.feed(Array("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789".utf8))
        XCTAssertEqual(done.first?.body, Data("0123".utf8))
        XCTAssertEqual(done.first?.bodySize, 10)
        XCTAssertEqual(done.first?.bodyTruncated, true)
    }

    func testStopsAtUpgradeAndHTTP2() {
        var parser = HTTPRequestParser()
        let upgrade = parser.feed(Array("GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n\u{81}\u{05}hello".utf8))
        XCTAssertEqual(upgrade.map(\.target), ["/ws"])
        XCTAssertTrue(parser.isStopped)
        XCTAssertEqual(parser.feed(Array("GET /later HTTP/1.1\r\n\r\n".utf8)), [])

        var h2 = HTTPRequestParser()
        XCTAssertEqual(h2.feed(Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)), [])
        XCTAssertTrue(h2.isStopped)
    }

    func testHostPortSplitting() {
        XCTAssertEqual(InspectorProxy.splitHostPort("API.Anthropic.com:443", defaultPort: 443)?.host, "api.anthropic.com")
        XCTAssertEqual(InspectorProxy.splitHostPort("example.com:8443", defaultPort: 443)?.port, 8443)
        XCTAssertEqual(InspectorProxy.splitHostPort("[::1]:9000", defaultPort: 443)?.host, "::1")
        XCTAssertEqual(InspectorProxy.splitHostPort("[::1]:9000", defaultPort: 443)?.port, 9000)
        XCTAssertNil(InspectorProxy.splitHostPort("evil.com/../x:443", defaultPort: 443))
        XCTAssertNil(InspectorProxy.splitHostPort("example.com:http", defaultPort: 443))
    }

    // MARK: - Finding git information

    private let scanner = UploadScanner(identity: GitIdentity(names: ["Ada Lovelace"], emails: ["ada@example.org"]),
                                        homeDirectory: "/Users/ada")

    private func kinds(in text: String) -> Set<UploadFindingKind> {
        Set(UploadScanner.findings(from: scanner.matches(in: text), in: text).map(\.kind))
    }

    /// The shape of what Claude Code puts in its system prompt, as it
    /// arrives inside a JSON string (newlines escaped).
    func testAgentPromptGitBlock() {
        let body = #"{"system":[{"type":"text","text":"Working directory: /Users/ada/work/secret-app\nIs directory a git repo: Yes\n\ngitStatus: This is the git status at the start of the conversation.\nCurrent branch: feature/payments\n\nMain branch (you will usually use this for PRs): main\n\nStatus:\nM src/billing.ts\n\nRecent commits:\n3f2a9c1 Add Stripe webhook\nb7e41d0 Fix rounding"}]}"#
        let found = UploadScanner.findings(from: scanner.matches(in: body), in: body)
        let byKind = Dictionary(uniqueKeysWithValues: found.map { ($0.kind, $0) })
        XCTAssertNotNil(byKind[.gitStatus])
        XCTAssertTrue(byKind[.gitStatus]?.samples.contains("Current branch: feature/payments") ?? false)
        XCTAssertEqual(Set(byKind[.gitCommit]?.samples ?? []), ["3f2a9c1", "b7e41d0"])
        XCTAssertEqual(byKind[.localPath]?.samples, ["/Users/ada/work/secret-app"])
    }

    func testRemotesIdentityAndGitFiles() {
        let text = #"""
        origin  git@github.com:acme/secret-app.git (fetch)
        url = https://gitlab.example.com/team/tool.git
        [remote "origin"]
        cat .git/config
        Author: Ada Lovelace <ada@example.org>
        contact: ADA@example.org
        """#
        let found = UploadScanner.findings(from: scanner.matches(in: text), in: text)
        let byKind = Dictionary(uniqueKeysWithValues: found.map { ($0.kind, $0) })
        XCTAssertEqual(Set(byKind[.gitRemote]?.samples ?? []),
                       ["git@github.com:acme/secret-app.git", "https://gitlab.example.com/team/tool.git"])
        XCTAssertNotNil(byKind[.gitFiles])
        XCTAssertGreaterThanOrEqual(byKind[.gitIdentity]?.count ?? 0, 3)
    }

    func testOrdinaryTextHasNothing() {
        let text = #"{"messages":[{"role":"user","content":"Please explain how decade-long trends in coffee prices work. See https://example.com/docs and /Users/adam/notes."}]}"#
        XCTAssertEqual(kinds(in: text), [])
    }

    func testGitConfigIdentity() {
        let config = """
        [core]
            editor = vim
        [user]
            name = Ada Lovelace
            email = ada@example.org # work
        [alias]
            name = not-a-user
        """
        XCTAssertEqual(GitIdentity.parse(config: config), GitIdentity(names: ["Ada Lovelace"], emails: ["ada@example.org"]))
    }

    // MARK: - Showing bodies

    func testCompressedBodiesAreDecoded() {
        let gzip = Data(base64Encoded: "H4sIAATAv2oC/6tWyssvSVWyUvLPU0gqSsxLzlDITczMU6oFAKUaoQkZAAAA")!
        let zlib = Data(base64Encoded: "eJyrVsrLL0lVslLyz1NIKkrMS85QyE3MzFOqBQBspAiB")!
        for (data, encoding) in [(gzip, "gzip"), (zlib, "deflate")] {
            let rendered = UploadBodyText.render(body: data, contentType: "application/json", contentEncoding: encoding)
            XCTAssertTrue(rendered.text.contains("On branch main"), "\(encoding): \(rendered.text)")
            XCTAssertEqual(kinds(in: rendered.text), [.gitStatus])
        }
    }

    func testCapturedUploadHidesCredentialsAndCollectsFindings() {
        let request = ParsedRequest(method: "POST", target: "/v1/upload?repo=git@github.com:acme/app.git", version: "HTTP/1.1",
                                    headers: [HeaderField(name: "Authorization", value: "Bearer sk-ant-0123456789abcdefghij"),
                                              HeaderField(name: "Content-Type", value: "application/json")],
                                    body: Data(#"{"cwd":"/Users/ada/app"}"#.utf8), bodySize: 24)
        let event = InspectorEvent(host: "api.example.com", port: 443, scheme: "https", pid: 42,
                                   processName: "node", request: request)
        let upload = CapturedUpload.make(from: event, scanner: scanner)
        XCTAssertEqual(upload.url, "https://api.example.com/v1/upload?repo=git@github.com:acme/app.git")
        XCTAssertEqual(upload.findings.map(\.kind), [.gitRemote, .localPath])
        XCTAssertTrue(upload.hasGit)
        let shown = CapturedUpload.displayValue(of: request.headers[0])
        XCTAssertFalse(shown.contains("abcdefghij"))
        XCTAssertTrue(shown.hasPrefix("Bearer sk-"))
    }
}
