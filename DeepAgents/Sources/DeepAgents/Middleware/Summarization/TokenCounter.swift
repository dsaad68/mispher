import Foundation

/// Estimates token counts for the summarization trigger and the context-usage meter — Mispher's
/// mirror of LangChain's `TokenCounter`. Kept behind a protocol so an exact, model-specific
/// tokenizer can be plugged in later; the default is a uniform character-based approximation that
/// works across every backend (local MLX and the cloud APIs, none of which expose a live counter).
public protocol TokenCounter: Sendable {
    /// Estimate the number of tokens in a plain string.
    func count(_ text: String) -> Int
}

public extension TokenCounter {
    /// Estimate the tokens a message list contributes to the prompt: visible text plus each
    /// tool call's name and argument rendering. Reasoning blocks are excluded because they are
    /// dropped when history is replayed (see ``AgentContentBlock``), so they never reach the model.
    func count(_ messages: [AgentMessage]) -> Int {
        messages.reduce(0) { $0 + count(tokenizableText(of: $1)) }
    }
}

/// The text in a message that contributes to the prompt — used by the default `count(_:)` over a
/// message list. Visible answer text plus any tool calls (name + argument rendering); reasoning and
/// images are not counted.
func tokenizableText(of message: AgentMessage) -> String {
    var parts = [message.text]
    for call in message.toolCalls {
        parts.append(call.name)
        if !call.describedArguments.isEmpty { parts.append(call.describedArguments) }
    }
    return parts.joined(separator: "\n")
}

/// LangChain's `count_tokens_approximately`: roughly four characters per token. Coarse, but the 85%
/// trigger leaves enough headroom to absorb the imprecision, and it needs no per-backend tokenizer.
public struct ApproximateTokenCounter: TokenCounter {
    /// Average characters per token used for the estimate.
    public let charactersPerToken: Int

    public init(charactersPerToken: Int = 4) {
        self.charactersPerToken = max(1, charactersPerToken)
    }

    public func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return (text.count + charactersPerToken - 1) / charactersPerToken
    }
}
