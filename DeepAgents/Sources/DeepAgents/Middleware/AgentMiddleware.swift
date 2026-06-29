import Foundation

/// A model invocation request flowing through the middleware chain — LangChain's
/// `ModelRequest`. Middleware produce a modified copy via `override(...)` before the
/// model runs (e.g. to append to the system prompt or filter the tool set).
public struct ModelRequest: Sendable {
    public var messages: [AgentMessage]
    public var systemPrompt: String?
    public var tools: [any AgentTool]

    /// Return a copy with selected fields replaced. Pass `.some(nil)` for
    /// `systemPrompt` to clear it; omit an argument to leave a field unchanged.
    public func override(
        messages: [AgentMessage]? = nil,
        systemPrompt: String?? = nil,
        tools: [any AgentTool]? = nil
    ) -> ModelRequest {
        ModelRequest(
            messages: messages ?? self.messages,
            systemPrompt: systemPrompt ?? self.systemPrompt,
            tools: tools ?? self.tools
        )
    }
}

/// The model's response for one agent turn.
public struct ModelResponse: Sendable {
    var message: AgentMessage
}

/// A single tool invocation flowing through the `wrapToolCall` chain.
public struct ToolCallRequest: Sendable {
    var call: AgentToolCall
    var state: AgentState
}

/// Agent middleware — Mispher's port of LangChain's `AgentMiddleware`. Override only
/// the hooks you need; all default to no-ops. `tools` contributes extra tools to the
/// agent. The `wrap*` hooks nest, with the first-registered middleware outermost.
public protocol AgentMiddleware: Sendable {
    /// A short identifier, for diagnostics.
    var name: String { get }
    /// Tools this middleware contributes to the agent.
    var tools: [any AgentTool] { get }

    /// Runs once before the loop begins.
    func beforeAgent(_ state: inout AgentState) async
    /// Runs before the model is called.
    func beforeModel(_ state: inout AgentState) async
    /// Runs after the model is called.
    func afterModel(_ state: inout AgentState) async
    /// Runs once after the loop completes.
    func afterAgent(_ state: inout AgentState) async

    /// Wrap the model call — call `handler` to proceed (optionally with a modified
    /// request), or short-circuit by returning a response without calling it.
    func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse

    /// Wrap a single tool call — for retries, monitoring, or result rewriting.
    func wrapToolCall(
        _ request: ToolCallRequest,
        _ handler: (ToolCallRequest) async throws -> AgentMessage
    ) async throws -> AgentMessage
}

extension AgentMiddleware {
    public var name: String { String(describing: Self.self) }
    public var tools: [any AgentTool] { [] }

    public func beforeAgent(_ state: inout AgentState) async {}
    public func beforeModel(_ state: inout AgentState) async {}
    public func afterModel(_ state: inout AgentState) async {}
    public func afterAgent(_ state: inout AgentState) async {}

    public func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        try await handler(request)
    }

    public func wrapToolCall(
        _ request: ToolCallRequest,
        _ handler: (ToolCallRequest) async throws -> AgentMessage
    ) async throws -> AgentMessage {
        try await handler(request)
    }
}
