import Foundation

/// One header line, in the order and spelling the client sent it.
struct HeaderField: Equatable {
    var name: String
    var value: String
}

/// One HTTP/1.x request read off a connection the upload inspector relays.
struct ParsedRequest: Equatable {
    var method: String
    var target: String
    var version: String
    var headers: [HeaderField]
    /// At most `HTTPRequestParser.maxBody` bytes of the body, de-chunked.
    var body: Data
    /// The body's real size, which `body` falls short of when it was cut.
    var bodySize: Int

    var bodyTruncated: Bool { body.count < bodySize }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Splits the client's side of an HTTP/1.x connection into requests, fed
/// whatever bytes arrive. It stops for good at anything that is no longer
/// HTTP/1 (a protocol upgrade such as a WebSocket, HTTP/2, garbage): the
/// bytes keep flowing to the server, they just aren't read as requests.
struct HTTPRequestParser {
    static let maxHead = 64 * 1024
    let maxBody: Int

    private enum State {
        case head
        case body(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkEnd
        case trailers
        case stopped
    }

    private var state: State = .head
    private var buffer: [UInt8] = []
    private var position = 0
    private var current: ParsedRequest?

    init(maxBody: Int = 8 << 20) {
        self.maxBody = maxBody
    }

    var isStopped: Bool {
        if case .stopped = state { return true }
        return false
    }

    mutating func feed(_ bytes: [UInt8]) -> [ParsedRequest] {
        if isStopped { return [] }
        buffer.append(contentsOf: bytes)
        var finished: [ParsedRequest] = []
        loop: while true {
            switch state {
            case .stopped:
                break loop
            case .head:
                guard let end = find([13, 10, 13, 10]) else {
                    if buffer.count - position > Self.maxHead { stop() }
                    break loop
                }
                let head = buffer[position..<end]
                position = end + 4
                guard let request = Self.parseHead(head) else { stop(); break loop }
                current = request
                let chunked = request.header("Transfer-Encoding")?.lowercased().contains("chunked") ?? false
                let length = request.header("Content-Length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
                if request.header("Upgrade") != nil {
                    // What follows the server's 101 isn't HTTP any more.
                    finish(into: &finished)
                    stop()
                } else if chunked {
                    state = .chunkSize
                } else if length > 0 {
                    state = .body(remaining: length)
                } else {
                    finish(into: &finished)
                }
            case .body(let remaining), .chunkData(let remaining):
                let available = buffer.count - position
                guard available > 0 else { break loop }
                let take = min(available, remaining)
                appendBody(buffer[position..<(position + take)])
                position += take
                let isChunk: Bool
                if case .chunkData = state { isChunk = true } else { isChunk = false }
                if take < remaining {
                    state = isChunk ? .chunkData(remaining: remaining - take) : .body(remaining: remaining - take)
                } else if isChunk {
                    state = .chunkEnd
                } else {
                    finish(into: &finished)
                }
            case .chunkSize:
                guard let end = find([13, 10]) else {
                    if buffer.count - position > 1024 { stop() }
                    break loop
                }
                let line = String(decoding: buffer[position..<end], as: UTF8.self)
                position = end + 2
                let digits = line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(digits, radix: 16), size >= 0 else { stop(); break loop }
                state = size == 0 ? .trailers : .chunkData(remaining: size)
            case .chunkEnd:
                guard buffer.count - position >= 2 else { break loop }
                position += 2
                state = .chunkSize
            case .trailers:
                guard let end = find([13, 10]) else { break loop }
                let empty = end == position
                position = end + 2
                if empty { finish(into: &finished) }
            }
        }
        if position > 0 {
            buffer.removeFirst(min(position, buffer.count))
            position = 0
        }
        return finished
    }

    private mutating func stop() {
        state = .stopped
        buffer = []
        position = 0
        current = nil
    }

    private mutating func appendBody(_ bytes: ArraySlice<UInt8>) {
        guard var request = current else { return }
        request.bodySize += bytes.count
        let room = maxBody - request.body.count
        if room > 0 { request.body.append(contentsOf: bytes.prefix(room)) }
        current = request
    }

    private mutating func finish(into finished: inout [ParsedRequest]) {
        if let request = current { finished.append(request) }
        current = nil
        state = .head
    }

    private func find(_ needle: [UInt8]) -> Int? {
        guard buffer.count - position >= needle.count else { return nil }
        var i = position
        let last = buffer.count - needle.count
        while i <= last {
            if buffer[i] == needle[0] {
                var match = true
                for j in 1..<needle.count where buffer[i + j] != needle[j] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    /// "POST /v1/messages HTTP/1.1" plus its header lines; nil for anything
    /// that isn't an HTTP/1 request head.
    static func parseHead(_ head: ArraySlice<UInt8>) -> ParsedRequest? {
        let text = String(decoding: head, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        let method = String(requestLine[0])
        guard !method.isEmpty, method.allSatisfy({ $0.isLetter && $0.isUppercase }) else { return nil }
        var headers: [HeaderField] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers.append(HeaderField(name: String(line[..<colon]),
                                       value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return ParsedRequest(method: method, target: String(requestLine[1]), version: String(requestLine[2]),
                             headers: headers, body: Data(), bodySize: 0)
    }
}
