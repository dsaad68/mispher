import Foundation

/// A reusable, testable recipe for one of Mispher's on-device ReAct agents: a top-level
/// system prompt plus a middleware stack. `make` wires them through ``createAgent(model:tools:systemPrompt:middleware:memory:maxIterations:messageLog:)``,
/// so each feature agent (Ask, Vision) is a few lines and is unit-testable with a
/// `FakeChatModel` — no model download.
///
/// Agents whose prompt is parameterized (e.g. translation, keyed by target language) or
/// that need a bespoke factory don't conform — they expose their own `make` instead.
public protocol AgentDefinition {
    /// The agent's top-level system prompt. Middleware may append further guidance via
    /// `wrapModelCall` (e.g. `ScreenshotMiddleware`'s screen-capture notes,
    /// `TodoListMiddleware`'s planning notes).
    static var systemPrompt: String { get }

    /// The middleware stack this agent runs with. Each entry also contributes its tools
    /// (the union becomes the agent's tool set). Returned fresh per call — the values are
    /// built per run, so there is no shared mutable state to reason about.
    static func middleware() -> [any AgentMiddleware]
}

extension AgentDefinition {
    /// Build a configured ``ReactAgent`` from this definition. Pass `memory` to give the
    /// agent thread-scoped short-term memory (nil = a single-turn run); `messageLog` is the
    /// optional JSONL transcript sink. `summarization` adds the always-on context-compaction
    /// pillar (the same one ``createDeepAgent`` wires), so a multi-turn chat on a plain Ask/Vision
    /// agent also compacts at 85%; pass `nil` to disable it. Its archive is wired automatically when
    /// `memory` also conforms to ``CompactionArchive``.
    public static func make(
        model: any ChatModel,
        memory: (any AgentCheckpointer)? = nil,
        messageLog: (any AgentMessageLog)? = nil,
        summarization: SummarizationConfig? = .default
    ) -> ReactAgent {
        var stack: [any AgentMiddleware] = []
        if let summarization {
            stack.append(SummarizationMiddleware(
                model: model, archive: memory as? CompactionArchive, config: summarization
            ))
        }
        stack += middleware()
        return createAgent(
            model: model,
            systemPrompt: systemPrompt,
            middleware: stack,
            memory: memory,
            messageLog: messageLog
        )
    }
}
