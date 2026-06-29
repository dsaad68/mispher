import Foundation
import MCP

/// Pure conversions between the agent core's value types and the MCP SDK's `Value`.
///
/// Mispher's tools speak `MLXLMCommon.AgentJSON` (what the model emits as tool-call
/// arguments) and `ToolSchema` (the `[String: any Sendable]` schema the chat template
/// renders). MCP speaks `MCP.Value`. This is the seam between the two — kept free of any
/// I/O so it can be unit-tested without a server (mirrors `langchain-mcp-adapters`'
/// schema/result conversion helpers).
public enum MCPValueBridge {
    // MARK: - Outgoing arguments (AgentJSON → MCP.Value)

    /// Convert a model-emitted argument into the `MCP.Value` the SDK's `callTool` expects.
    static func toMCPValue(_ value: AgentJSON) -> Value {
        switch value {
        case .null: return .null
        case .bool(let bool): return .bool(bool)
        case .int(let int): return .int(int)
        case .double(let double): return .double(double)
        case .string(let string): return .string(string)
        case .array(let array): return .array(array.map(toMCPValue))
        case .object(let object): return .object(object.mapValues(toMCPValue))
        }
    }

    /// Convert a full argument bag; `nil` when empty so the SDK omits the field.
    static func toMCPArguments(_ arguments: [String: AgentJSON]) -> [String: Value]? {
        arguments.isEmpty ? nil : arguments.mapValues(toMCPValue)
    }

    // MARK: - Input schema (MCP.Value → ToolSchema parameters block)

    /// Render an MCP tool's `inputSchema` (a JSON Schema carried as `MCP.Value`) into the
    /// native `[String: any Sendable]` object the chat template renders for the
    /// `function.parameters` field. Non-object schemas fall back to an empty object schema
    /// so the model still sees a well-formed parameters block.
    public static func schemaObject(_ value: Value) -> [String: any Sendable] {
        if let object = value.objectValue {
            return object.mapValues(sendable)
        }
        return ["type": "object", "properties": [String: any Sendable]()]
    }

    /// A native, `Sendable` projection of an `MCP.Value` for chat-template rendering.
    /// Mirrors `AgentJSON.jinjaSendable`: `null` becomes an empty string so the template
    /// still renders something.
    static func sendable(_ value: Value) -> any Sendable {
        switch value {
        case .null: return ""
        case .bool(let bool): return bool
        case .int(let int): return int
        case .double(let double): return double
        case .string(let string): return string
        case .data(_, let data): return data.base64EncodedString()
        case .array(let array): return array.map(sendable)
        case .object(let object): return object.mapValues(sendable)
        }
    }

    // MARK: - Tool result (MCP content → text)

    /// Flatten an MCP `callTool` result's content blocks into the single string the model
    /// sees next turn. Text blocks pass through; non-text blocks (image/audio/resource)
    /// become a short descriptor — v1 is text-first, matching `langchain-mcp-adapters`'
    /// default handling.
    static func text(from content: [MCP.Tool.Content]) -> String {
        content.map { block in
            switch block {
            case .text(let text, _, _):
                return text
            case .image(_, let mimeType, _, _):
                return "[image: \(mimeType)]"
            case .audio(_, let mimeType, _, _):
                return "[audio: \(mimeType)]"
            case .resource:
                return "[embedded resource]"
            case .resourceLink(let uri, let name, _, _, _, _):
                return "[resource: \(name) (\(uri))]"
            }
        }
        .joined(separator: "\n")
    }
}
