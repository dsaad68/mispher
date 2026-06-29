import Foundation

/// Build a ReAct agent — Mispher's port of LangChain's `create_agent`.
///
/// The agent's tool set is the union of `tools` and every tool contributed by
/// `middleware` (so e.g. `TodoListMiddleware`'s `write_todos` and
/// `ClipboardMiddleware`'s `read_clipboard` / `write_clipboard` are registered
/// automatically). Pass a `memory` checkpointer to give the agent thread-scoped
/// short-term memory. Works for both text LLMs and VLMs — the model decides whether to
/// consume images via `ChatModel.supportsVision`.
public func createAgent(
    model: any ChatModel,
    tools: [any AgentTool] = [],
    systemPrompt: String? = nil,
    middleware: [any AgentMiddleware] = [],
    memory: (any AgentCheckpointer)? = nil,
    maxIterations: Int = 24,
    disabledToolNames: Set<String> = [],
    messageLog: (any AgentMessageLog)? = nil
) -> ReactAgent {
    // The union of explicit and middleware-contributed tools, minus any the user deactivated.
    // This is the single place tool deactivation takes effect: a dropped tool is never rendered
    // into the prompt nor dispatchable, so the agent behaves as if it didn't exist.
    let allTools = (tools + middleware.flatMap { $0.tools })
        .filter { !disabledToolNames.contains($0.name) }
    return ReactAgent(
        model: model,
        tools: allTools,
        systemPrompt: systemPrompt,
        middleware: middleware,
        memory: memory,
        maxIterations: maxIterations,
        messageLog: messageLog
    )
}
