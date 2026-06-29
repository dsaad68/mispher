import Foundation

/// Build a deep agent — Mispher's port of LangChain deepagents' `create_deep_agent`.
///
/// A deep agent is the ReAct core (``createAgent(model:tools:systemPrompt:middleware:memory:maxIterations:messageLog:)``)
/// plus deepagents' built-in middleware pillars: **planning** (`TodoListMiddleware` →
/// `write_todos`), a shared **filesystem** (`FilesystemMiddleware` →
/// `ls`/`read_file`/`write_file`/`edit_file`), and **subagents** (`SubAgentMiddleware` → `task`).
/// Hand it `subagents` to let the main agent delegate isolated subtasks; a general-purpose subagent
/// is available by default.
///
/// One ``FilesystemBackend`` is resolved here (the caller's `backend`, else an in-memory
/// ``StateBackend``) and shared by reference with both the main agent and every subagent, so files
/// written anywhere in the run are visible everywhere.
///
/// Human-in-the-loop (deepagents' `interrupt_on`): pass `interruptOn` plus an `approvalHandler` to
/// gate those tools behind the user's approve / edit / reject decision. The resulting
/// ``HumanInTheLoopMiddleware`` is registered on the main agent AND threaded into every subagent,
/// so a delegated subtask can't bypass the approval gate (in LangGraph, subgraph interrupts
/// propagate the same way).
///
/// - Parameters:
///   - model: the chat model the agent (and, by default, its subagents) runs on.
///   - tools: the agent's own tools; subagents whose `tools` is `nil` inherit these.
///   - systemPrompt: extra instructions, composed after the base deep-agent prompt.
///   - subagents: custom subagents the `task` tool can delegate to.
///   - middleware: extra middleware, appended after the built-in deep-agent stack.
///   - memory: optional thread-scoped short-term memory.
///   - backend: where the filesystem tools store files (default: a fresh in-memory `StateBackend`).
///   - interruptOn: tool name → human-in-the-loop policy; effective only with `approvalHandler`.
///   - approvalHandler: presents an interrupted call to the user and returns their decision.
///   - askUserHandler: presents the agent's `ask_user` questions to the user and returns their
///     answers. When set, an ``AskUserMiddleware`` is registered on the main agent so the model can
///     pause to ask for clarification; without it the `ask_user` tool is absent.
///   - includeFilesystem: register the filesystem pillar (default `true`).
///   - includeGeneralPurpose: register the built-in general-purpose subagent (default `true`).
///   - disabledToolNames: tools to drop from the agent entirely (the user's deactivations).
public func createDeepAgent(
    model: any ChatModel,
    tools: [any AgentTool] = [],
    systemPrompt: String? = nil,
    subagents: [SubAgent] = [],
    middleware: [any AgentMiddleware] = [],
    memory: (any AgentCheckpointer)? = nil,
    backend: (any FilesystemBackend)? = nil,
    interruptOn: [String: InterruptOnConfig] = [:],
    approvalHandler: ToolApprovalHandler? = nil,
    askUserHandler: AskUserHandler? = nil,
    includeFilesystem: Bool = true,
    includeGeneralPurpose: Bool = true,
    maxIterations: Int = 24,
    disabledToolNames: Set<String> = [],
    messageLog: (any AgentMessageLog)? = nil,
    summarization: SummarizationConfig? = .default
) -> ReactAgent {
    let fileBackend: (any FilesystemBackend)? = includeFilesystem ? (backend ?? StateBackend()) : nil

    let humanInTheLoop: HumanInTheLoopMiddleware? = {
        guard let approvalHandler, !interruptOn.isEmpty else { return nil }
        return HumanInTheLoopMiddleware(interruptOn: interruptOn, approvalHandler: approvalHandler)
    }()

    let composedPrompt = [DeepAgentPrompt.system(includeFilesystem: includeFilesystem), systemPrompt]
        .compactMap { $0 }
        .joined(separator: "\n\n")

    // The built-in deep-agent stack (planning, then filesystem, then subagents), followed by any
    // caller-supplied middleware, with human-in-the-loop last so it gates every tool. Order
    // mirrors deepagents' assembly in `create_deep_agent`. Summarization goes first so its
    // `beforeModel` compacts the history before the other hooks read it; its archive is wired
    // automatically when the caller's `memory` checkpointer also conforms to `CompactionArchive`.
    var stack: [any AgentMiddleware] = []
    if let summarization {
        stack.append(SummarizationMiddleware(
            model: model, archive: memory as? CompactionArchive, config: summarization
        ))
    }
    stack.append(TodoListMiddleware())
    if let fileBackend { stack.append(FilesystemMiddleware(backend: fileBackend)) }
    stack.append(
        SubAgentMiddleware(
            model: model,
            baseTools: tools,
            subagents: subagents,
            backend: fileBackend,
            humanInTheLoop: humanInTheLoop,
            includeGeneralPurpose: includeGeneralPurpose
        )
    )
    stack += middleware
    // Let the agent pause to ask the user for clarification, when the host can present it.
    if let askUserHandler { stack.append(AskUserMiddleware(handler: askUserHandler)) }
    if let humanInTheLoop { stack.append(humanInTheLoop) }

    return createAgent(
        model: model,
        tools: tools,
        systemPrompt: composedPrompt,
        middleware: stack,
        memory: memory,
        maxIterations: maxIterations,
        disabledToolNames: disabledToolNames,
        messageLog: messageLog
    )
}
