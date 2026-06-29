import DeepAgents
import Foundation

/// AWS credentials for signing Bedrock requests. The session token is optional (set for temporary
/// STS/role credentials). ``fromEnvironment()`` reads the standard AWS variables - the only
/// credential source Ripple's Bedrock models use, keeping secrets out of `settings.json`.
public struct BedrockCredentials: Sendable, Equatable {
    public let accessKey: String
    public let secretKey: String
    public let sessionToken: String?

    public init(accessKey: String, secretKey: String, sessionToken: String? = nil) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.sessionToken = sessionToken
    }

    /// Build credentials from `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / optional
    /// `AWS_SESSION_TOKEN`, or nil when the required pair isn't set.
    public static func fromEnvironment() -> BedrockCredentials? {
        let env = ProcessInfo.processInfo.environment
        guard let accessKey = env["AWS_ACCESS_KEY_ID"], !accessKey.isEmpty,
              let secretKey = env["AWS_SECRET_ACCESS_KEY"], !secretKey.isEmpty
        else { return nil }
        let token = env["AWS_SESSION_TOKEN"]
        return BedrockCredentials(
            accessKey: accessKey, secretKey: secretKey,
            sessionToken: (token?.isEmpty == false) ? token : nil
        )
    }
}

/// How a Bedrock request is authenticated: AWS SigV4 request signing (access-key credentials) or a
/// bearer token - an Amazon Bedrock API key sent as `Authorization: Bearer <token>`. The two are
/// mutually exclusive; a bearer token replaces SigV4 signing entirely, matching AWS's behavior.
public enum BedrockAuth: Sendable, Equatable {
    case sigV4(BedrockCredentials)
    case bearerToken(String)

    /// Resolve Bedrock auth, preferring a bearer token over SigV4 (matching AWS, where
    /// `AWS_BEARER_TOKEN_BEDROCK` takes precedence). `bearerToken` is an explicit token (e.g. the
    /// Ripple `apiKey` field); when nil/empty it falls back to the `AWS_BEARER_TOKEN_BEDROCK`
    /// environment variable, then to SigV4 access-key credentials. Returns nil when none are set.
    public static func resolve(bearerToken: String? = nil) -> BedrockAuth? {
        if let bearerToken, !bearerToken.isEmpty { return .bearerToken(bearerToken) }
        if let token = ProcessInfo.processInfo.environment["AWS_BEARER_TOKEN_BEDROCK"], !token.isEmpty {
            return .bearerToken(token)
        }
        if let credentials = BedrockCredentials.fromEnvironment() { return .sigV4(credentials) }
        return nil
    }
}

/// A `ChatModel` over **Anthropic models on AWS Bedrock**, via the Bedrock Runtime
/// `invoke-with-response-stream` API. Speaks the same Messages wire format as ``AnthropicChatModel``
/// (it reuses ``AnthropicMessageCodec`` and ``AnthropicDecoder``), but authenticates each request via
/// ``BedrockAuth`` (SigV4 signing or a bearer token) and reads the AWS event-stream framing instead of
/// SSE. Pure Foundation + CryptoKit; no AWS SDK.
public struct BedrockChatModel: ChatModel {
    let region: String
    /// The Bedrock model or cross-region inference-profile id (e.g. `us.anthropic.claude-opus-4-8`).
    let model: String
    let auth: BedrockAuth
    /// Endpoint base used verbatim (one trailing `/` trimmed), e.g.
    /// `https://bedrock-runtime.us-east-1.amazonaws.com`. When nil the endpoint is derived from `region`.
    let baseURL: String?
    public let supportsVision: Bool
    public var modelID: String?
    public var contextWindowTokens: Int?
    let parameters: AnthropicGenerateParameters
    let transport: any BedrockStreamingTransport

    public init(
        region: String,
        model: String,
        auth: BedrockAuth,
        baseURL: String? = nil,
        supportsVision: Bool = false,
        modelID: String? = nil,
        contextWindowTokens: Int? = nil,
        parameters: AnthropicGenerateParameters = .init(),
        transport: (any BedrockStreamingTransport)? = nil
    ) {
        self.region = region
        self.model = model
        self.auth = auth
        self.baseURL = baseURL
        self.supportsVision = supportsVision
        self.modelID = modelID ?? model
        self.contextWindowTokens = contextWindowTokens
        self.parameters = parameters
        self.transport = transport ?? URLSessionBedrockTransport()
    }

    public func makeSession() -> any ModelTurnSession {
        BedrockTurnSession(
            region: region, model: model, auth: auth, baseURL: baseURL,
            supportsVision: supportsVision, parameters: parameters, transport: transport
        )
    }
}

/// An error from the Bedrock Runtime endpoint - a non-2xx response body, an in-stream exception
/// frame, or a model id that can't form a valid endpoint URL.
public enum BedrockModelError: Error, CustomStringConvertible {
    case http(status: Int, body: String)
    case stream(String)
    case badModelID(String)

    public var description: String {
        switch self {
        case .http(let status, let body):
            let detail = body.isEmpty ? "" : ": \(body)"
            return "Bedrock request failed (HTTP \(status))\(detail)"
        case .stream(let message):
            return "Bedrock stream error: \(message)"
        case .badModelID(let model):
            return "Invalid Bedrock model id: \(model)"
        }
    }
}
