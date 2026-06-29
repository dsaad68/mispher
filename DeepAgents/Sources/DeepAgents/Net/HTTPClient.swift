import Foundation

/// The minimal async HTTP surface the web tools (`fetch`, `curl`, `download`) need. A
/// protocol so tests inject a stub instead of hitting the network; the live implementation
/// is a thin `URLSession` wrapper. Foundation only - no third-party HTTP dependency.
public protocol HTTPClient: Sendable {
    /// Perform `request`, following redirects, and return the response plus raw body bytes.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// One outbound HTTP request.
public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(
        url: URL, method: String = "GET", headers: [String: String] = [:],
        body: Data? = nil, timeout: TimeInterval = 30
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// The response to an ``HTTPRequest``.
public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    /// The URL the request ended on (after any redirects).
    public var finalURL: URL
    public var mimeType: String?

    public init(
        statusCode: Int, headers: [String: String], body: Data,
        finalURL: URL, mimeType: String?
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
        self.mimeType = mimeType
    }

    /// True when the body looks textual (decodes as UTF-8 and the MIME type isn't binary).
    public var bodyText: String? { String(data: body, encoding: .utf8) }
}

/// The live HTTP client - a `URLSession` wrapper that follows redirects and supplies a
/// default User-Agent.
public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession
    let userAgent: String

    public init(session: URLSession = .shared, userAgent: String = "ripple/1.0 (+MispherCore)") {
        self.session = session
        self.userAgent = userAgent
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        if urlRequest.value(forHTTPHeaderField: "User-Agent") == nil {
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        urlRequest.httpBody = request.body

        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(
            statusCode: http?.statusCode ?? 0,
            headers: headers,
            body: data,
            finalURL: response.url ?? request.url,
            mimeType: http?.mimeType ?? response.mimeType
        )
    }
}

/// Reduce an HTML document to readable plain text for a small model: drop the non-content
/// blocks (`script`/`style`/`head`/comments), turn block-level tags into line breaks, strip
/// the rest, and decode the common entities. A dependency-free heuristic - not a full
/// parser, but good enough to feed the model the page's words instead of its markup.
public enum HTMLText {
    public static func plainText(from html: String) -> String {
        var text = html

        // Strip blocks whose contents are never prose.
        for pattern in [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<head[^>]*>[\\s\\S]*?</head>",
            "<!--[\\s\\S]*?-->"
        ] {
            text = replace(pattern, in: text, with: " ")
        }

        // Block-level boundaries become newlines so the text keeps some structure.
        text = replace("(?i)<(br|/p|/div|/li|/tr|/h[1-6]|/section|/article)[^>]*>", in: text, with: "\n")
        text = replace("(?i)<li[^>]*>", in: text, with: "\n- ")
        // Drop every remaining tag.
        text = replace("<[^>]+>", in: text, with: "")

        text = decodeEntities(text)

        // Collapse runs of spaces/tabs and excess blank lines.
        text = replace("[ \\t]+", in: text, with: " ")
        text = replace("\\n[ \\t]+", in: text, with: "\n")
        text = replace("\\n{3,}", in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ input: String) -> String {
        var text = input
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "-", "&ndash;": "-"
        ]
        for (entity, value) in named { text = text.replacingOccurrences(of: entity, with: value) }

        // Numeric references: &#123; (decimal) and &#x1F600; (hex).
        for (pattern, radix) in [("&#([0-9]+);", 10), ("&#[xX]([0-9A-Fa-f]+);", 16)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: text),
                      let digits = Range(match.range(at: 1), in: text),
                      let code = UInt32(text[digits], radix: radix),
                      let scalar = Unicode.Scalar(code)
                else { continue }
                text.replaceSubrange(whole, with: String(scalar))
            }
        }
        return text
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }
}
