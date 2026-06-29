@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import Testing

// Tests for attributing namespaced MCP tools (`server__tool`) back to their server: the dispatch
// prefix, the per-server approval-default map, and the display projection that the MCP Servers tab
// uses to reflect the agent's live (warm) tool set.

@Suite("MCP tool ↔ server mapping")
struct MCPMappingTests {
    @Test("dispatchPrefix sanitizes the server name")
    func dispatchPrefix() {
        #expect(MCPTool.dispatchPrefix(forServer: "parallel-search") == "parallel-search__")
        #expect(MCPTool.dispatchPrefix(forServer: "deepwiki") == "deepwiki__")
        #expect(MCPTool.dispatchPrefix(forServer: "my server") == "my_server__") // space → underscore
    }

    @Test("mcpApprovalDefaults maps each tool to its server's mode; unmatched tools get none")
    func approvalDefaults() {
        let servers = [
            MCPServerConfig(name: "parallel-search", kind: .http, approvalMode: .ask),
            MCPServerConfig(name: "deepwiki", kind: .http, approvalMode: .approve)
        ]
        let tools: [any AgentTool] = [
            StubTool("parallel-search__web_search"),
            StubTool("parallel-search__web_fetch"),
            StubTool("deepwiki__ask"),
            StubTool("other__thing") // belongs to no configured server
        ]
        let defaults = mcpApprovalDefaults(servers: servers, tools: tools)

        #expect(defaults["parallel-search__web_search"] == .ask)
        #expect(defaults["parallel-search__web_fetch"] == .ask)
        #expect(defaults["deepwiki__ask"] == .approve)
        #expect(defaults["other__thing"] == nil)
    }

    @Test("mcpToolsForDisplay attributes tools to a server, strips the prefix, keeps the schema")
    func displayProjection() {
        let tools: [any AgentTool] = [
            SchemaTool("parallel-search__web_search", description: "Search the web"),
            SchemaTool("parallel-search__web_fetch", description: "Fetch a URL"),
            SchemaTool("deepwiki__ask", description: "Ask the wiki")
        ]

        let parallel = mcpToolsForDisplay(server: "parallel-search", in: tools)
        #expect(parallel.map(\.name).sorted() == ["web_fetch", "web_search"])
        let search = parallel.first { $0.name == "web_search" }
        #expect(search?.dispatchName == "parallel-search__web_search")
        #expect(search?.description == "Search the web")
        #expect(search?.schema["type"] as? String == "object")

        let deepwiki = mcpToolsForDisplay(server: "deepwiki", in: tools)
        #expect(deepwiki.map(\.dispatchName) == ["deepwiki__ask"])
    }

    @Test("mcpToolsForDisplay returns nothing for a server with no matching tools")
    func displayProjectionEmpty() {
        let tools: [any AgentTool] = [SchemaTool("deepwiki__ask", description: "Ask")]
        #expect(mcpToolsForDisplay(server: "parallel-search", in: tools).isEmpty)
    }
}

/// A minimal `AgentTool` with a chosen name (default schema).
private struct StubTool: AgentTool {
    let name: String
    init(_ name: String) { self.name = name }
    var description: String { "stub" }
    var parameters: [ToolParameter] { [] }
    func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        ToolOutput("ok")
    }
}

/// An `AgentTool` that injects a known `toolSchema()` schema (the way ``MCPTool`` does), so the
/// display projection's schema extraction can be asserted.
private struct SchemaTool: AgentTool {
    let name: String
    let desc: String
    init(_ name: String, description: String) {
        self.name = name
        desc = description
    }

    var description: String { desc }
    var parameters: [ToolParameter] { [] }
    func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        ToolOutput("ok")
    }

    func toolSchema() -> ToolSchema {
        let schema: [String: any Sendable] = ["type": "object", "properties": [String: any Sendable]()]
        return [
            "type": "function",
            "function": ["name": name, "description": desc, "parameters": schema] as [String: any Sendable]
        ]
    }
}
