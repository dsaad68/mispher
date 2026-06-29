import Foundation

/// Abstraction over the underlying chat model — Mispher's mirror of LangChain's
/// `BaseChatModel`. The model is a **factory for run-scoped sessions**: `ReactAgent`
/// owns the ReAct loop and asks the model to open one `ModelTurnSession` per run, then
/// drives it one turn per round. Keeping this behind a protocol lets the agent core stay
/// independent of `mlx-swift-lm`.
///
/// The `ChatModel` value itself is `Sendable` (it's just configuration — e.g. a
/// `ModelContainer`); the `ModelTurnSession` it vends is stateful and is not.
public protocol ChatModel: Sendable {
    /// Whether this model can accept image input (so the agent only attaches images
    /// for VLMs).
    var supportsVision: Bool { get }

    /// Identifier for the developer message log (e.g. the Hugging Face repo id), so a
    /// transcript records which model generated each turn. `nil` when unknown.
    var modelID: String? { get }

    /// The model's maximum context window in tokens, when known — what summarization measures
    /// its 85% trigger against, and what the context-usage meter divides by. `nil` when unknown
    /// (callers fall back to a conservative default).
    var contextWindowTokens: Int? { get }

    /// Open a run-scoped session. The session is stateless — `ReactAgent` passes the full
    /// conversation (and the per-round system prompt and tools) to
    /// `ModelTurnSession.nextTurn` every round — so nothing needs to be seeded here.
    func makeSession() -> any ModelTurnSession
}

extension ChatModel {
    public var modelID: String? { nil }
    public var contextWindowTokens: Int? { nil }
}
