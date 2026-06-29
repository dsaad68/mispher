import Foundation

/// Sampling parameters for an Anthropic Messages request. `maxTokens` is required by the
/// Messages API, so it falls back to a default at body-build time when unset; `temperature`
/// and `topP` are omitted from the body when nil so the server applies its own default.
/// Mirrors ``OpenAIGenerateParameters`` (DeepAgentsOpenAI) for the Anthropic wire format.
public struct AnthropicGenerateParameters: Sendable, Equatable {
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?

    public init(maxTokens: Int? = nil, temperature: Double? = nil, topP: Double? = nil) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }

    /// The `max_tokens` the body sends — the configured value, or a sensible default since the
    /// Messages API rejects a request without one.
    var resolvedMaxTokens: Int { maxTokens ?? 4096 }
}
