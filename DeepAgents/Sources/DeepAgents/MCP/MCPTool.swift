import Foundation
import MCP

enum MCPToolError: LocalizedError {
    case toolFailed(name: String, message: String)

    var errorDescription: String? {
        switch self {
        case .toolFailed(let name, let message):
            return "MCP tool '\(name)' failed: \(message)"
        }
    }
}

/// An `AgentTool` that proxies to a tool on an MCP server — Mispher's analogue of
/// `langchain-mcp-adapters`' `convert_mcp_tool_to_langchain_tool`.
///
/// The exposed `name` is namespaced `server__tool` so tools from different servers never
/// collide; the original (unprefixed) `toolName` is what we send back to the server. The
/// server's own JSON Schema is injected verbatim by overriding ``toolSchema()`` — which is
/// why `AgentTool` declares `toolSchema()` as a requirement, so this override is honored
/// through the `any AgentTool` existential the model layer iterates.
public struct MCPTool: AgentTool {
    /// Logical server name, used as the tool-name prefix.
    let serverName: String
    /// The tool's name on the server (what `callTool` is invoked with).
    let toolName: String
    let toolDescription: String
    /// The tool's JSON Schema, as advertised by the server.
    let inputSchema: Value
    let session: any MCPSession
    /// An explicit dispatch name set by the loader to break a collision (e.g. two servers
    /// that sanitize to the same prefix). When `nil`, the derived namespaced name is used.
    var nameOverride: String?

    /// The namespaced name the model and `ReactAgent` dispatch on. Both components are
    /// sanitized to `[A-Za-z0-9_-]` because a user-chosen server name (or an unusual
    /// server-side tool name) containing spaces/punctuation may not round-trip through the
    /// chat template and tool-call parser, which would make `ReactAgent`'s exact-match
    /// dispatch fail with "unknown tool". The server is still invoked with the original
    /// `toolName` (see `execute`), so sanitizing the exposed name is safe.
    public var name: String { nameOverride ?? Self.dispatchName(server: serverName, tool: toolName) }
    public var description: String { toolDescription }

    /// The default namespaced dispatch name for a server/tool pair.
    public static func dispatchName(server: String, tool: String) -> String {
        "\(sanitize(server))__\(sanitize(tool))"
    }

    /// The dispatch-name prefix (`sanitize(server)__`) every tool a server contributes shares,
    /// so a caller holding only `[any AgentTool]` can attribute tools back to their server by
    /// prefix (e.g. to apply that server's approval mode).
    public static func dispatchPrefix(forServer server: String) -> String {
        "\(sanitize(server))__"
    }

    /// Map any character outside `[A-Za-z0-9_-]` to `_`; never returns an empty string.
    static func sanitize(_ component: String) -> String {
        let mapped = component.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_"
                || character == "-")
                ? character : "_"
        }
        return mapped.isEmpty ? "_" : String(mapped)
    }

    /// Inject the server-provided schema directly, rather than rebuilding it from
    /// `parameters` (which an MCP tool doesn't have) — so nested objects/arrays and every
    /// constraint the server declares survive into the chat template.
    public func toolSchema() -> ToolSchema {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": MCPValueBridge.schemaObject(inputSchema)
            ] as [String: any Sendable]
        ]
    }

    public func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        let (content, isError) = try await session.callTool(
            name: toolName, arguments: MCPValueBridge.toMCPArguments(arguments)
        )
        let text = MCPValueBridge.text(from: content)
        // An MCP error result is recoverable: thrown here, `ReactAgent.dispatchTool` turns
        // it into an `Error: …` tool message so the model can react rather than aborting.
        if isError == true {
            throw MCPToolError.toolFailed(name: name, message: text)
        }
        return ToolOutput(text)
    }
}
