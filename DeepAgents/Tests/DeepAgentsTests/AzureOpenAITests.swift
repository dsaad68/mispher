@testable import DeepAgents
@testable import DeepAgentsOpenAI
import Foundation
import Testing

/// Tests the Azure flavor of the OpenAI adapter: the deployment-path URL with the `api-version`
/// query item, and the `api-key` auth header (vs `Authorization: Bearer` for the standard style).
struct AzureOpenAITests {
    @Test func azureEndpointBuildsDeploymentURLWithAPIVersion() throws {
        let base = try #require(URL(string: "https://my-res.openai.azure.com"))
        let url = OpenAIChatModel.endpoint(
            baseURL: base, style: .azure(deployment: "gpt-4o", apiVersion: "2024-10-21")
        )
        #expect(url.absoluteString
            == "https://my-res.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21")
    }

    @Test func standardEndpointAppendsChatCompletions() throws {
        let base = try #require(URL(string: "https://api.openai.com/v1"))
        let url = OpenAIChatModel.endpoint(baseURL: base, style: .standard)
        #expect(url.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test func azureSendsAPIKeyHeaderNotBearer() async throws {
        let base = try #require(URL(string: "https://my-res.openai.azure.com"))
        let transport = HeaderCapturingTransport()
        let model = OpenAIChatModel(
            baseURL: base, model: "gpt-4o", apiKey: "secret",
            auth: .apiKey, endpointStyle: .azure(deployment: "gpt-4o", apiVersion: "2024-10-21"),
            transport: transport
        )
        _ = try await model.makeSession().nextTurn(
            messages: [.human("hi")], systemPrompt: nil, tools: []
        ) { _ in }
        #expect(transport.headers?["api-key"] == "secret")
        #expect(transport.headers?["Authorization"] == nil)
    }

    @Test func standardSendsBearerHeader() async throws {
        let base = try #require(URL(string: "https://h/v1"))
        let transport = HeaderCapturingTransport()
        let model = OpenAIChatModel(baseURL: base, model: "m", apiKey: "secret", transport: transport)
        _ = try await model.makeSession().nextTurn(
            messages: [.human("hi")], systemPrompt: nil, tools: []
        ) { _ in }
        #expect(transport.headers?["Authorization"] == "Bearer secret")
        #expect(transport.headers?["api-key"] == nil)
    }
}

/// Records the outgoing request headers, then returns an empty stream.
private final class HeaderCapturingTransport: OpenAIStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String: String]?

    var headers: [String: String]? { lock.withLock { captured } }

    func send(
        _ request: URLRequest
    ) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        lock.withLock { captured = request.allHTTPHeaderFields }
        return (200, AsyncThrowingStream { $0.finish() })
    }
}
