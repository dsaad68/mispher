import Foundation

/// A specialized child agent the deep agent can delegate isolated subtasks to — Mispher's port of
/// LangChain deepagents' `SubAgent`. The main agent invokes one through the `task` tool by `name`
/// (the `subagent_type`); the subagent then runs as its own `ReactAgent` with a fresh conversation
/// (just the delegated task), its own system prompt, and — optionally — its own tools and model,
/// and returns a single final result to the parent. Its intermediate work never enters the parent's
/// context, which is the whole point: context isolation and token efficiency.
///
/// `tools` and `model` are optional and follow deepagents' inheritance rules: `nil` means "inherit
/// the deep agent's" (its base tool set / shared model). An explicit `[]` gives the subagent no
/// tools at all.
public struct SubAgent: Sendable {
    /// Unique identifier — the value the main agent passes as `subagent_type`.
    var name: String
    /// What this subagent is for. Surfaced to the main agent (in the `task` tool and prompt) so it
    /// knows when to delegate here.
    var description: String
    /// The subagent's system prompt. Required — subagents do not inherit the parent's prompt.
    var systemPrompt: String
    /// Tools the subagent may use. `nil` inherits the deep agent's base tools; `[]` means none.
    var tools: [any AgentTool]?
    /// Model override. `nil` inherits the deep agent's model.
    var model: (any ChatModel)?
    /// Extra middleware to run the subagent with (e.g. its own planning, logging, or rate limiting).
    var middleware: [any AgentMiddleware]
    /// Hard cap on the subagent's ReAct rounds.
    var maxIterations: Int

    public init(
        name: String,
        description: String,
        systemPrompt: String,
        tools: [any AgentTool]? = nil,
        model: (any ChatModel)? = nil,
        middleware: [any AgentMiddleware] = [],
        maxIterations: Int = 24
    ) {
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.model = model
        self.middleware = middleware
        self.maxIterations = maxIterations
    }
}
