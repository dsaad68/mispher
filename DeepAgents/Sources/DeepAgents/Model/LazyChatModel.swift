import Foundation

/// A `ChatModel` that defers loading the real model until the first turn actually runs.
///
/// The deep agent's `vision` subagent (and, on the planner side, the chat model that may have been
/// idle-unloaded between turns) shouldn't pin weights in memory just because it's *configured* — the
/// VLM in particular should load only when the planner delegates a visual question. This wrapper makes
/// that possible: the agent treats it as an ordinary model (it reports `supportsVision` / `modelID` /
/// `contextWindowTokens` **statically**, so image-attachment gating and the context meter work without
/// loading anything), and only when a round actually generates does `begin` resolve — and, if needed,
/// load — the underlying model. `end` runs after the round so the owner can (re)start an idle timer.
///
/// Resolving per round is cheap and correct here because the MLX model node is stateless
/// (`RebuildTurnSession` rebuilds the prompt from the full message list every round), so re-vending a
/// session after an idle reload loses nothing.
public struct LazyChatModel: ChatModel {
    public let supportsVision: Bool
    public let modelID: String?
    public let contextWindowTokens: Int?

    /// Resolve the underlying model, loading it if it isn't resident, and mark it in active use (so an
    /// idle timer can't unload it mid-round). Throws if the model can't be loaded.
    let begin: @Sendable () async throws -> any ChatModel
    /// Mark the model no longer in active use for this round, so the owner can (re)schedule its idle
    /// unload. Always called once per `begin`, on both success and failure.
    let end: @Sendable () async -> Void

    public init(
        supportsVision: Bool,
        modelID: String?,
        contextWindowTokens: Int?,
        begin: @escaping @Sendable () async throws -> any ChatModel,
        end: @escaping @Sendable () async -> Void
    ) {
        self.supportsVision = supportsVision
        self.modelID = modelID
        self.contextWindowTokens = contextWindowTokens
        self.begin = begin
        self.end = end
    }

    public func makeSession() -> any ModelTurnSession {
        LazySession(begin: begin, end: end)
    }
}

/// One run's lazy model node: each `nextTurn` resolves (loading on demand) the underlying model,
/// vends a fresh session from it, and delegates. `end` runs after every round — including a thrown
/// one — so the idle timer is rearmed whether the turn succeeded or failed.
private final class LazySession: ModelTurnSession {
    private let begin: @Sendable () async throws -> any ChatModel
    private let end: @Sendable () async -> Void

    init(
        begin: @escaping @Sendable () async throws -> any ChatModel,
        end: @escaping @Sendable () async -> Void
    ) {
        self.begin = begin
        self.end = end
    }

    func nextTurn(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [any AgentTool],
        onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
    ) async throws -> AgentMessage {
        let model = try await begin()
        do {
            let message = try await model.makeSession().nextTurn(
                messages: messages, systemPrompt: systemPrompt, tools: tools, onChunk: onChunk
            )
            await end()
            return message
        } catch {
            await end()
            throw error
        }
    }
}
