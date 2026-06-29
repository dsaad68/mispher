import DeepAgents
import Foundation

/// A `ChatModel` over any **OpenAI-compatible** chat-completions endpoint (a custom `baseURL`
/// + api key + model name) - the framework's second backend alongside on-device `MlxChatModel`.
/// Pure Foundation (URLSession); no MLX. Because the agent loop already speaks `AgentMessage`
/// and `AgentTool.toolSchema()` already emits the OpenAI `{type:"function", …}` shape, this
/// adapter only has to render the conversation, POST it, and stream the reply back.
///
/// Each run gets one `OpenAITurnSession`. The model node is single-shot and stateless: every
/// round `ReactAgent` hands the session the full conversation, which it renders to the
/// chat-completions `messages` array, streams one response, and surfaces any `tool_calls` to
/// the agent (it does not dispatch them).
public struct OpenAIChatModel: ChatModel {
    /// The API root that holds `/chat/completions` (commonly ends in `/v1`), matching
    /// `ChatOpenAI(openai_api_base:)`. For Azure (``OpenAIEndpointStyle/azure``) it's the resource
    /// root (e.g. `https://my-resource.openai.azure.com`).
    let baseURL: URL
    let model: String
    let apiKey: String?
    public let supportsVision: Bool
    public var modelID: String?
    public var contextWindowTokens: Int?
    let parameters: OpenAIGenerateParameters
    /// Ask the endpoint to stream chain-of-thought (OpenRouter's `reasoning` param). Off by default.
    let reasoning: Bool
    /// How the api key is sent: `Authorization: Bearer` (OpenAI/OpenRouter) or `api-key` (Azure).
    let auth: OpenAIAuthStyle
    /// How the request URL is formed: the standard `/chat/completions` path, or Azure's
    /// deployment path with the `api-version` query item.
    let endpointStyle: OpenAIEndpointStyle
    let transport: any OpenAIStreamingTransport

    public init(
        baseURL: URL,
        model: String,
        apiKey: String? = nil,
        supportsVision: Bool = false,
        modelID: String? = nil,
        contextWindowTokens: Int? = nil,
        parameters: OpenAIGenerateParameters = .init(),
        reasoning: Bool = false,
        auth: OpenAIAuthStyle = .bearer,
        endpointStyle: OpenAIEndpointStyle = .standard,
        transport: (any OpenAIStreamingTransport)? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.supportsVision = supportsVision
        self.modelID = modelID ?? model
        self.contextWindowTokens = contextWindowTokens
        self.parameters = parameters
        self.reasoning = reasoning
        self.auth = auth
        self.endpointStyle = endpointStyle
        self.transport = transport ?? URLSessionStreamingTransport()
    }

    public func makeSession() -> any ModelTurnSession {
        OpenAITurnSession(
            endpoint: Self.endpoint(baseURL: baseURL, style: endpointStyle),
            apiKey: apiKey,
            auth: auth,
            supportsVision: supportsVision,
            codec: OpenAIMessageCodec(model: model, parameters: parameters, reasoning: reasoning),
            transport: transport
        )
    }

    /// The chat-completions URL for an endpoint style. Standard appends `chat/completions` to the
    /// `/v1` root; Azure forms `{root}/openai/deployments/{deployment}/chat/completions?api-version=…`.
    static func endpoint(baseURL: URL, style: OpenAIEndpointStyle) -> URL {
        switch style {
        case .standard:
            return baseURL.appending(path: "chat/completions")
        case .azure(let deployment, let apiVersion):
            let url = baseURL.appending(path: "openai/deployments").appending(path: deployment)
                .appending(path: "chat/completions")
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "api-version", value: apiVersion)]
            return components.url ?? url
        }
    }
}

/// How the api key is presented on a request: the OpenAI/OpenRouter `Authorization: Bearer` header,
/// or Azure OpenAI's `api-key` header.
public enum OpenAIAuthStyle: Sendable {
    case bearer
    case apiKey
}

/// How a request URL is formed for a chat-completions endpoint.
public enum OpenAIEndpointStyle: Sendable, Equatable {
    /// `{baseURL}/chat/completions` - OpenAI, OpenRouter, and any OpenAI-compatible endpoint.
    case standard
    /// Azure OpenAI: `{baseURL}/openai/deployments/{deployment}/chat/completions?api-version=…`.
    case azure(deployment: String, apiVersion: String)
}

/// An error from an OpenAI-compatible endpoint - a non-2xx response, with the body text so the
/// agent's error surface shows the server's message (a bad key, an unknown model, a rate limit).
public enum OpenAIModelError: Error, CustomStringConvertible {
    case http(status: Int, body: String)

    public var description: String {
        switch self {
        case .http(let status, let body):
            let detail = body.isEmpty ? "" : ": \(body)"
            return "OpenAI request failed (HTTP \(status))\(detail)"
        }
    }
}
