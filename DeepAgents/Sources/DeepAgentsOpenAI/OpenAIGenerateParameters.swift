import Foundation

/// Sampling parameters for an OpenAI-compatible chat-completions request. Every field is
/// optional: an unset value is omitted from the request body so the server applies its own
/// default. Parallels `MlxChatModel.generateParameters`, trimmed to what the chat-completions
/// schema accepts directly (`temperature`, `top_p`, `max_tokens`).
public struct OpenAIGenerateParameters: Sendable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?

    public init(temperature: Double? = nil, topP: Double? = nil, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }
}
