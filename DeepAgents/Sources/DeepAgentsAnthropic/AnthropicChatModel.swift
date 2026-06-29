import DeepAgents
import Foundation

/// A `ChatModel` over the **Anthropic Messages API** (`POST {baseURL}/v1/messages`) - a cloud
/// backend alongside on-device `MlxChatModel` and the OpenAI-compatible adapter. Pure Foundation
/// (URLSession); no MLX. The agent loop already speaks `AgentMessage`, so this adapter only renders
/// the conversation into the Messages body, POSTs it with `x-api-key` + `anthropic-version`, and
/// streams the Server-Sent-Events reply back through ``AnthropicDecoder``.
public struct AnthropicChatModel: ChatModel {
    let baseURL: URL
    let model: String
    let apiKey: String?
    public let supportsVision: Bool
    public var modelID: String?
    public var contextWindowTokens: Int?
    let parameters: AnthropicGenerateParameters
    /// The `anthropic-version` header value (the API's dated contract, not the model id).
    let anthropicVersion: String
    /// Optional `anthropic-beta` feature flags, sent comma-joined when non-empty.
    let betaHeaders: [String]
    let transport: any AnthropicStreamingTransport

    public init(
        baseURL: URL,
        model: String,
        apiKey: String? = nil,
        supportsVision: Bool = false,
        modelID: String? = nil,
        contextWindowTokens: Int? = nil,
        parameters: AnthropicGenerateParameters = .init(),
        anthropicVersion: String = "2023-06-01",
        betaHeaders: [String] = [],
        transport: (any AnthropicStreamingTransport)? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.supportsVision = supportsVision
        self.modelID = modelID ?? model
        self.contextWindowTokens = contextWindowTokens
        self.parameters = parameters
        self.anthropicVersion = anthropicVersion
        self.betaHeaders = betaHeaders
        self.transport = transport ?? URLSessionStreamingTransport()
    }

    public func makeSession() -> any ModelTurnSession {
        AnthropicTurnSession(
            endpoint: baseURL.appending(path: "v1/messages"),
            apiKey: apiKey,
            anthropicVersion: anthropicVersion,
            betaHeaders: betaHeaders,
            supportsVision: supportsVision,
            codec: AnthropicMessageCodec(model: model, parameters: parameters),
            transport: transport
        )
    }
}

/// An error from the Anthropic Messages endpoint - a non-2xx response (with the body text so the
/// agent's error surface shows the server's message), or an `error` event delivered mid-stream
/// after a 200 (e.g. an `overloaded_error`), which must not be mistaken for a finished turn.
public enum AnthropicModelError: Error, CustomStringConvertible {
    case http(status: Int, body: String)
    case stream(String)

    public var description: String {
        switch self {
        case .http(let status, let body):
            let detail = body.isEmpty ? "" : ": \(body)"
            return "Anthropic request failed (HTTP \(status))\(detail)"
        case .stream(let message):
            return "Anthropic stream error: \(message)"
        }
    }
}
