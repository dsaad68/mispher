import DeepAgents
import MLXLMCommon

extension AgentToolCall {
    /// Map from `mlx-swift-lm`'s `ToolCall`, bridging its `JSONValue` arguments to ``AgentJSON``.
    /// The MLX adapter's half of the tool-call bridge (the framework's ``AgentToolCall`` stays
    /// backend-neutral).
    init(_ toolCall: ToolCall) {
        self.init(
            name: toolCall.function.name,
            arguments: toolCall.function.arguments.mapValues(AgentJSON.init)
        )
    }
}
