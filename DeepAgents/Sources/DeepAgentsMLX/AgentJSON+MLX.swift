import DeepAgents
import MLXLMCommon

/// 1:1 bridge between the framework-owned ``AgentJSON`` and `mlx-swift-lm`'s `JSONValue`.
/// The cases are identical, so each direction is a mechanical map — this is the seam that
/// lets the agent core speak `AgentJSON` while the MLX backend speaks `JSONValue`.
extension AgentJSON {
    /// Build an ``AgentJSON`` from `mlx-swift-lm`'s `JSONValue`.
    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .int(value)
        case .double(let value): self = .double(value)
        case .string(let value): self = .string(value)
        case .array(let value): self = .array(value.map(AgentJSON.init))
        case .object(let value): self = .object(value.mapValues(AgentJSON.init))
        }
    }

    /// Project this value back to `mlx-swift-lm`'s `JSONValue`.
    var mlxJSONValue: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .array(let value): return .array(value.map(\.mlxJSONValue))
        case .object(let value): return .object(value.mapValues(\.mlxJSONValue))
        }
    }
}
