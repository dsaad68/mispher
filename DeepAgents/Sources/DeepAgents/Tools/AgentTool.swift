import Foundation

/// Context handed to a tool at execution time — Mispher's lightweight mirror of
/// LangChain's `ToolRuntime`. Carries a read-only snapshot of the conversation so a
/// tool can inspect state if it needs to. `Sendable` so tools run off the main actor.
public struct ToolContext: Sendable {
    /// The agent state visible to the tool (read-only).
    let state: AgentState
    /// Sink for streaming sub-events while the tool runs — e.g. the `task` tool forwards a
    /// subagent's tokens as `.toolProgress` so the UI shows them live. Defaults to a no-op, so
    /// tools that don't stream (the vast majority) can ignore it.
    let onEvent: @Sendable (AgentEvent) -> Void

    init(
        state: AgentState = .init(),
        onEvent: @escaping @Sendable (AgentEvent) -> Void = { _ in }
    ) {
        self.state = state
        self.onEvent = onEvent
    }
}

/// What a tool returns: the textual result the model sees next turn, plus an optional
/// state update (LangChain's `Command`) the runtime applies to the agent state.
public struct ToolOutput: Sendable {
    var content: String
    var stateUpdate: AgentStateUpdate?

    public init(_ content: String, stateUpdate: AgentStateUpdate? = nil) {
        self.content = content
        self.stateUpdate = stateUpdate
    }
}

/// A callable tool the agent can invoke — Mispher's mirror of a LangChain `BaseTool`.
/// A conformer declares a JSON-schema interface (`parameters`) and an async `execute`.
/// The generated schema is injected into the chat template by `mlx-swift-lm`.
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: [ToolParameter] { get }
    func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput

    /// The `mlx-swift-lm` tool schema injected into the chat template. A protocol
    /// requirement (not just an extension method) so a conformer that already holds a
    /// server-provided JSON Schema — e.g. ``MCPTool`` — can override it to inject that
    /// schema verbatim through the `any AgentTool` existential. Most tools rely on the
    /// default below, which builds the schema from `parameters`.
    func toolSchema() -> ToolSchema
}

extension AgentTool {
    public var parameters: [ToolParameter] { [] }

    /// Build the `mlx-swift-lm` tool schema (`ToolSchema`) injected into the chat
    /// template — same shape as `MLXLMCommon.Tool`'s generated schema.
    public func toolSchema() -> ToolSchema {
        var properties: [String: any Sendable] = [:]
        var required: [String] = []
        for parameter in parameters {
            properties[parameter.name] = parameter.schema
            if parameter.isRequired { required.append(parameter.name) }
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ] as [String: any Sendable]
            ] as [String: any Sendable]
        ]
    }
}
