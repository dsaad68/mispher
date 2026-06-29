import Foundation

/// The agent's working state through one run — Mispher's mirror of LangChain's
/// `AgentState`. `messages` is the conversation; `values` is an extensible bag that
/// middleware use for their own state (e.g. the to-do list lives under `"todos"`).
public struct AgentState: Sendable {
    public var messages: [AgentMessage]
    public var values: [String: any Sendable]
    /// Control-flow override a middleware can set to steer the loop (`jump_to`).
    public var jumpTo: JumpTarget?

    public init(
        messages: [AgentMessage] = [],
        values: [String: any Sendable] = [:],
        jumpTo: JumpTarget? = nil
    ) {
        self.messages = messages
        self.values = values
        self.jumpTo = jumpTo
    }
}

/// Where a middleware wants the loop to go next — LangChain's `jump_to`.
public enum JumpTarget: Sendable { case model, tools, end }

/// A partial state mutation a tool returns — LangChain's `Command(update=…)`. The
/// runtime merges `values` into the agent state after the tool runs.
public struct AgentStateUpdate: Sendable {
    public var values: [String: any Sendable]

    public init(_ values: [String: any Sendable] = [:]) { self.values = values }

    /// Convenience for the common single-key update.
    public static func set(_ key: String, _ value: any Sendable) -> AgentStateUpdate {
        .init([key: value])
    }
}
