import Foundation

/// Web middleware - gives the agent `fetch` (read a page as text) and `curl` (raw HTTP),
/// plus the guidance for using them. Network-only, so it needs no working-folder root.
/// Both tools share one ``HTTPClient`` (a `URLSession` wrapper by default, a stub in tests).
public struct WebToolsMiddleware: AgentMiddleware {
    let client: any HTTPClient

    public init(client: any HTTPClient = URLSessionHTTPClient()) { self.client = client }

    public var name: String { "web" }
    public var tools: [any AgentTool] { [FetchTool(client: client), CurlTool(client: client)] }

    public func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        let composed = [request.systemPrompt, Self.systemPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return try await handler(request.override(systemPrompt: composed))
    }

    public static let systemPrompt = """
    ## Web with `fetch` / `curl`
    Use `fetch` to read a web page or document - it returns the page as readable text (HTML \
    is stripped to its words). Use `curl` for raw HTTP when you need a specific method, \
    custom headers, or a request body, or to see the status code and response headers. Never \
    claim you can't reach the internet without trying `fetch` first; if a request fails, \
    report the status.
    """
}

/// `fetch`: GET a URL and return its contents as readable text (HTML reduced to words).
public struct FetchTool: AgentTool {
    let client: any HTTPClient
    public var name: String { "fetch" }
    public var description: String {
        "Fetch a URL over HTTP(S) and return its contents as readable text (HTML is stripped)."
    }

    public var parameters: [ToolParameter] {
        [.required("url", type: .string, description: "The URL to fetch (http or https).")]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let raw = ToolArgs.string(arguments, "url"), let url = WebTools.url(from: raw) else {
            return ToolOutput("Error: a valid http(s) `url` is required.")
        }
        do {
            let response = try await client.send(HTTPRequest(url: url))
            let header = "GET \(response.finalURL.absoluteString) -> \(response.statusCode)"
            return ToolOutput("\(header)\n\n\(WebTools.readableBody(response))")
        } catch {
            return ToolOutput("Error: couldn't fetch \(url.absoluteString): \(error.localizedDescription)")
        }
    }
}

/// `curl`: make an arbitrary HTTP request and return the status, headers, and raw body.
public struct CurlTool: AgentTool {
    let client: any HTTPClient
    public var name: String { "curl" }
    public var description: String {
        "Make an HTTP request and return the status, response headers, and raw body. "
            + "Use for non-GET methods, custom headers, or a request body."
    }

    public var parameters: [ToolParameter] {
        [
            .required("url", type: .string, description: "The URL to request (http or https)."),
            .optional(
                "method", type: .string, description: "HTTP method (default GET).",
                extraProperties: ["enum": ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]]
            ),
            .optional(
                "headers", type: .object(properties: []),
                description: "Request headers as a JSON object of name/value strings."
            ),
            .optional("body", type: .string, description: "Request body (for POST/PUT/PATCH).")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let raw = ToolArgs.string(arguments, "url"), let url = WebTools.url(from: raw) else {
            return ToolOutput("Error: a valid http(s) `url` is required.")
        }
        let method = (ToolArgs.string(arguments, "method") ?? "GET").uppercased()
        guard WebTools.methods.contains(method) else {
            return ToolOutput("Error: unsupported method \"\(method)\". Use one of \(WebTools.methods.joined(separator: ", ")).")
        }
        let headers = ToolArgs.stringMap(arguments, "headers")
        let body = ToolArgs.rawString(arguments, "body").map { Data($0.utf8) }
        do {
            let response = try await client.send(
                HTTPRequest(url: url, method: method, headers: headers, body: body)
            )
            return ToolOutput(WebTools.rawSummary(method: method, response: response))
        } catch {
            return ToolOutput("Error: \(method) \(url.absoluteString) failed: \(error.localizedDescription)")
        }
    }
}

/// Shared helpers for the web tools (also used by `download`).
public enum WebTools {
    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
    /// Bytes of body text returned to the model before truncating.
    static let maxBodyBytes = 200_000

    /// Validate `raw` as an http(s) URL with a host, or nil.
    public static func url(from raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    /// `fetch`'s body: HTML reduced to text, other text as-is, binary noted.
    static func readableBody(_ response: HTTPResponse) -> String {
        let mime = response.mimeType?.lowercased() ?? ""
        guard let text = response.bodyText else {
            return "[binary content: \(mime.isEmpty ? "unknown type" : mime), \(response.body.count) bytes]"
        }
        let head = text.prefix(512).lowercased()
        let isHTML = mime.contains("html") || head.contains("<html") || head.contains("<!doctype")
        return clip(isHTML ? HTMLText.plainText(from: text) : text)
    }

    /// `curl`'s raw summary: a status line, sorted headers, then the body.
    static func rawSummary(method: String, response: HTTPResponse) -> String {
        var lines = ["\(method) \(response.finalURL.absoluteString) -> \(response.statusCode)"]
        for (key, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        let body = response.bodyText.map(clip) ?? "[binary content: \(response.body.count) bytes]"
        return lines.joined(separator: "\n") + "\n\n" + body
    }

    static func clip(_ text: String) -> String {
        guard text.utf8.count > maxBodyBytes else { return text }
        let bytes = Array(text.utf8.prefix(maxBodyBytes))
        // The byte prefix may split a multi-byte character; fall back to a character prefix.
        let prefix = String(bytes: bytes, encoding: .utf8) ?? String(text.prefix(maxBodyBytes))
        return prefix + "\n… (truncated)"
    }
}
