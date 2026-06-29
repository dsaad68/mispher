import Foundation

/// A run-scoped model session — Mispher's single-shot model node. Mirrors the role the
/// `model` node plays in LangChain's agent graph: given the conversation so far, produce
/// **one** assistant turn (visible text and/or tool calls) and stop. It does **not**
/// dispatch tools — the agent (`ReactAgent`) owns the ReAct loop and dispatches tools
/// between turns.
///
/// A session is created once per `ReactAgent.run` (via `ChatModel.makeSession`) and then
/// `nextTurn` is called once per ReAct round, with the **full** conversation each round.
/// The model node is stateless: the prompt is a pure function of `messages`, rebuilt and
/// generated from a fresh cache every round (`RebuildTurnSession`). That keeps the engine
/// honest — what the model sees is exactly what we pass — and lets middleware rewrite
/// history (trim/summarise) or a `wrapModelCall` retry re-invoke the handler, neither of
/// which a live KV cache could honor.
public protocol ModelTurnSession: AnyObject {
    /// Generate exactly one assistant turn from the whole conversation so far.
    /// - Parameters:
    ///   - messages: the full conversation to condition on (prior turns + this run's input
    ///     + any tool results from earlier rounds). The system prompt is supplied
    ///     separately; do not include it here.
    ///   - systemPrompt: the (possibly middleware-composed) system prompt for this round.
    ///   - tools: the tools available this round (already middleware-filtered).
    ///   - onChunk: receives streamed pieces of this round - visible answer `text` and, on a
    ///     reasoning model, `reasoning` (chain-of-thought) on its own channel.
    /// - Returns: an `.ai(text, toolCalls:)` message. Stops at the tool calls of one pass.
    func nextTurn(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [any AgentTool],
        onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
    ) async throws -> AgentMessage
}
