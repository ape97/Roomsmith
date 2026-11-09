import Foundation

// Presenter mode: the HTTP side of the stream server as pure functions (no sockets), so it can be tested exactly.

public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable { case get = "GET", head = "HEAD" }

    public var method: Method
    /// Path without query string, still percent-encoded as sent.
    public var path: String
    public var version: String
    /// Lower-cased names.
    public var headers: [String: String]

    /// HTTP/1.0 or `Connection: close`.
    public var wantsClose: Bool {
        if version == "HTTP/1.0" { return headers["connection"]?.lowercased() != "keep-alive" }
        return headers["connection"]?.lowercased().contains("close") == true
    }
}

public enum HTTPParseResult: Sendable, Equatable {
    /// The header block is not complete yet.
    case needMoreData
    /// A request and the number of bytes it used (no body is ever accepted).
    case request(HTTPRequest, consumed: Int)
    /// Unacceptable input: answer with this status and close.
    case reject(status: Int)
}

public enum HTTPRequestParser {
    /// Longest accepted header block including the request line.
    public static let maxHeaderBytes = 8 * 1024
    public static let maxHeaderCount = 64
    public static let maxPathBytes = 512

    private static let terminator = Data("\r\n\r\n".utf8)

    public static func parse(_ data: Data) -> HTTPParseResult {
        guard let end = data.range(of: terminator) else {
            return data.count > maxHeaderBytes ? .reject(status: 431) : .needMoreData
        }
        guard end.upperBound <= maxHeaderBytes else { return .reject(status: 431) }
        guard let head = String(data: data[data.startIndex ..< end.lowerBound], encoding: .utf8) else { return .reject(status: 400) }
        let lines = head.components(separatedBy: "\r\n")
        guard lines.count - 1 <= maxHeaderCount else { return .reject(status: 431) }

        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .reject(status: 400) }
        let methodText = String(parts[0]), target = String(parts[1]), version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { return .reject(status: 505) }
        guard let method = HTTPRequest.Method(rawValue: methodText) else {
            // Real methods we do not serve vs. garbage.
            let known: Set<String> = ["POST", "PUT", "DELETE", "PATCH", "OPTIONS", "CONNECT", "TRACE"]
            return .reject(status: known.contains(methodText) ? 405 : 400)
        }
        guard let path = sanitizedPath(target) else { return .reject(status: 400) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .reject(status: 400) }
            let name = line[..<colon]
            guard name.allSatisfy({ $0.isASCII && $0 != " " && $0 != "\t" }) else { return .reject(status: 400) }
            headers[name.lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // This server has no use for request bodies; refuse them instead of mis-framing the next request.
        if headers["content-length"].map({ $0 != "0" }) == true || headers["transfer-encoding"] != nil { return .reject(status: 400) }
        return .request(HTTPRequest(method: method, path: path, version: version, headers: headers), consumed: end.upperBound)
    }

    /// Request target to a plain absolute path; nil if it could escape the stream directory or is malformed.
    /// Rejects encoded dots and slashes, backslashes, control characters and over-long targets.
    public static func sanitizedPath(_ target: String) -> String? {
        guard target.utf8.count <= maxPathBytes, target.hasPrefix("/"), !target.hasPrefix("//") else { return nil }
        var path = target
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
        let lower = path.lowercased()
        for bad in ["%2e", "%2f", "%5c", "%00", "%25"] where lower.contains(bad) { return nil }
        for scalar in path.unicodeScalars {
            if scalar.value < 0x21 || scalar.value == 0x7F || scalar == "\\" || scalar.value > 0x7E { return nil }
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        for (i, seg) in segments.enumerated() {
            if seg == "." || seg == ".." { return nil }
            if seg.isEmpty, i != segments.count - 1 { return nil }
        }
        return path
    }
}

/// Maps a request path to the name of a served file.
public enum HLSRoute {
    /// `/<token>/<name>` with the exact token and a plain file name; otherwise nil (answer 404, never reveal why).
    public static func resourceName(path: String, token: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { return nil }
        guard constantTimeEquals(String(parts[1]), token) else { return nil }
        let name = String(parts[2])
        guard !name.isEmpty, name.count <= 64,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }),
              !name.hasPrefix(".") else { return nil }
        return name
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0 ..< max(x.count, y.count) {
            diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    /// 128-bit random token as 32 hex characters (system random source).
    public static func makeToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0 ..< 2).map { _ in String(g.next() as UInt64, radix: 16).leftPadded(16) }.joined()
    }
}

extension String {
    fileprivate func leftPadded(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}

/// Single byte range of a `Range` header.
public enum HTTPRange {
    /// `bytes=a-b`, `bytes=a-`, `bytes=-n` against a body of `length` bytes. nil: ignore the header (serve everything);
    /// `.unsatisfiable`: answer 416.
    public enum Result: Equatable, Sendable { case range(ClosedRange<Int>), unsatisfiable }

    public static func parse(_ header: String?, length: Int) -> Result? {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        let a = Int(spec[0].trimmingCharacters(in: .whitespaces)), b = Int(spec[1].trimmingCharacters(in: .whitespaces))
        switch (a, b) {
        case let (start?, end?):
            guard start <= end else { return nil }
            guard start < length else { return .unsatisfiable }
            return .range(start ... min(end, length - 1))
        case let (start?, nil):
            guard start < length else { return .unsatisfiable }
            return .range(start ... (length - 1))
        case let (nil, suffix?):
            guard suffix > 0, length > 0 else { return .unsatisfiable }
            return .range(max(0, length - suffix) ... (length - 1))
        default:
            return nil
        }
    }
}

/// Builds response bytes.
public enum HTTPResponse {
    public static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 505: "HTTP Version Not Supported"
        default: "Error"
        }
    }

    /// Complete response. `body` is omitted for HEAD (the length is still announced).
    public static func make(status: Int, contentType: String = "text/plain; charset=utf-8", body: Data = Data(),
                            includeBody: Bool = true, contentRange: String? = nil, close: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if let contentRange { head += "Content-Range: \(contentRange)\r\n" }
        head += "Accept-Ranges: bytes\r\n"
        head += "Cache-Control: no-cache, no-store\r\n"
        head += "Connection: \(close ? "close" : "keep-alive")\r\n"
        head += "X-Content-Type-Options: nosniff\r\n\r\n"
        var out = Data(head.utf8)
        if includeBody { out.append(body) }
        return out
    }

    /// Answer to a parsed request for a named resource.
    public static func answer(_ request: HTTPRequest, resource: HLSResource?) -> Data {
        let close = request.wantsClose
        guard let resource else { return make(status: 404, body: Data("Not found\n".utf8), includeBody: request.method == .get, close: close) }
        let include = request.method == .get
        switch HTTPRange.parse(request.headers["range"], length: resource.data.count) {
        case .range(let r)?:
            return make(status: 206, contentType: resource.contentType, body: resource.data.subdata(in: r.lowerBound ..< r.upperBound + 1),
                        includeBody: include, contentRange: "bytes \(r.lowerBound)-\(r.upperBound)/\(resource.data.count)", close: close)
        case .unsatisfiable?:
            return make(status: 416, contentRange: "bytes */\(resource.data.count)", close: close)
        case nil:
            return make(status: 200, contentType: resource.contentType, body: resource.data, includeBody: include, close: close)
        }
    }
}
