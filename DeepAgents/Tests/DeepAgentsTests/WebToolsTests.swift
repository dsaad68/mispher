@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// The `web` tools against a stub ``HTTPClient`` (no network), plus the pure HTML->text reducer.
struct WebToolsTests {
    private struct StubClient: HTTPClient {
        let response: HTTPResponse
        func send(_ request: HTTPRequest) async throws -> HTTPResponse { response }
    }

    private func stub(
        _ body: String, mime: String = "text/html", status: Int = 200
    ) throws -> StubClient {
        let url = try #require(URL(string: "https://example.com/page"))
        return StubClient(response: HTTPResponse(
            statusCode: status, headers: ["Content-Type": mime],
            body: Data(body.utf8), finalURL: url, mimeType: mime
        ))
    }

    @Test func fetchStripsHTMLToText() async throws {
        let client = try stub("<html><body><h1>Hi</h1><p>World &amp; co</p><script>ignore()</script></body></html>")
        let output = try await FetchTool(client: client).execute(
            ["url": .string("https://example.com")], ToolContext()
        )
        #expect(output.content.contains("Hi"))
        #expect(output.content.contains("World & co"))
        #expect(!output.content.contains("ignore"))
        #expect(!output.content.contains("<h1>"))
    }

    @Test func fetchRejectsNonHTTPURL() async throws {
        let client = try stub("x")
        let output = try await FetchTool(client: client).execute(
            ["url": .string("file:///etc/passwd")], ToolContext()
        )
        #expect(output.content.contains("Error"))
    }

    @Test func curlReportsStatusAndBody() async throws {
        let client = try stub("{\"ok\":true}", mime: "application/json")
        let output = try await CurlTool(client: client).execute(
            ["url": .string("https://example.com"), "method": .string("get")], ToolContext()
        )
        #expect(output.content.contains("-> 200"))
        #expect(output.content.contains("{\"ok\":true}"))
    }

    @Test func curlRejectsUnsupportedMethod() async throws {
        let client = try stub("x")
        let output = try await CurlTool(client: client).execute(
            ["url": .string("https://example.com"), "method": .string("TRACE")], ToolContext()
        )
        #expect(output.content.contains("Error"))
    }

    @Test func htmlTextDecodesEntities() {
        let text = HTMLText.plainText(from: "<p>a &amp; b &#65; &#x42;</p>")
        #expect(text.contains("a & b A B"))
    }
}
