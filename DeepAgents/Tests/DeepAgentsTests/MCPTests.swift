@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MCP
import MLXLMCommon
import Testing

// Tests for the MCP client layer. They exercise the value/schema/result conversions and
// the tool-loading logic without a real server, using a `FakeMCPSession` — the same
// dependency-injection approach the agent tests use with `FakeChatModel`.

/// An in-memory `MCPSession`: returns scripted tools and a scripted `callTool` result, and
/// records the last call so tests can assert argument conversion and unprefixed names.
actor FakeMCPSession: MCPSession {
    let scriptedTools: [MCP.Tool]
    let result: (content: [MCP.Tool.Content], isError: Bool?)
    let failConnect: Bool
    private(set) var lastCall: (name: String, arguments: [String: Value]?)?

    init(
        tools: [MCP.Tool],
        result: (content: [MCP.Tool.Content], isError: Bool?) = (
            [.text(text: "ok", annotations: nil, _meta: nil)], nil
        ),
        failConnect: Bool = false
    ) {
        scriptedTools = tools
        self.result = result
        self.failConnect = failConnect
    }

    struct ConnectFailed: Error {}

    func connect() async throws { if failConnect { throw ConnectFailed() } }
    func listTools() async throws -> [MCP.Tool] { scriptedTools }
    func callTool(
        name: String, arguments: [String: Value]?
    ) async throws -> (content: [MCP.Tool.Content], isError: Bool?) {
        lastCall = (name, arguments)
        return result
    }

    func disconnect() async {}
}

private let objectSchema: Value = [
    "type": "object",
    "properties": ["q": ["type": "string", "description": "query"]],
    "required": ["q"]
]

// MARK: - Value bridge

struct MCPValueBridgeTests {
    @Test func convertsEachJSONValueCase() {
        #expect(MCPValueBridge.toMCPValue(.string("a")) == .string("a"))
        #expect(MCPValueBridge.toMCPValue(.int(7)) == .int(7))
        #expect(MCPValueBridge.toMCPValue(.double(1.5)) == .double(1.5))
        #expect(MCPValueBridge.toMCPValue(.bool(true)) == .bool(true))
        #expect(MCPValueBridge.toMCPValue(.null) == .null)
        #expect(MCPValueBridge.toMCPValue(.array([.int(1), .int(2)])) == .array([.int(1), .int(2)]))
        #expect(
            MCPValueBridge.toMCPValue(.object(["k": .string("v")])) == .object(["k": .string("v")])
        )
    }

    @Test func emptyArgumentsBecomeNil() {
        #expect(MCPValueBridge.toMCPArguments([:]) == nil)
        #expect(MCPValueBridge.toMCPArguments(["q": .string("hi")]) == ["q": .string("hi")])
    }

    @Test func schemaObjectPreservesNestedStructure() {
        let object = MCPValueBridge.schemaObject(objectSchema)
        #expect(object["type"] as? String == "object")
        let properties = object["properties"] as? [String: any Sendable]
        let q = properties?["q"] as? [String: any Sendable]
        #expect(q?["type"] as? String == "string")
        #expect((object["required"] as? [any Sendable])?.first as? String == "q")
    }

    @Test func nonObjectSchemaFallsBack() {
        let object = MCPValueBridge.schemaObject(.string("oops"))
        #expect(object["type"] as? String == "object")
    }

    @Test func flattensContentBlocksToText() {
        let content: [MCP.Tool.Content] = [
            .text(text: "hello", annotations: nil, _meta: nil),
            .image(data: "AAAA", mimeType: "image/png", annotations: nil, _meta: nil)
        ]
        #expect(MCPValueBridge.text(from: content) == "hello\n[image: image/png]")
    }
}

// MARK: - MCPTool

struct MCPToolTests {
    private func tool(
        result: (content: [MCP.Tool.Content], isError: Bool?) = (
            [.text(text: "ok", annotations: nil, _meta: nil)], nil
        )
    ) -> (MCPTool, FakeMCPSession) {
        let session = FakeMCPSession(
            tools: [MCP.Tool(name: "search", description: "Search", inputSchema: objectSchema)],
            result: result
        )
        let tool = MCPTool(
            serverName: "srv", toolName: "search", toolDescription: "Search",
            inputSchema: objectSchema, session: session
        )
        return (tool, session)
    }

    @Test func namespacesNameWithServer() {
        let (tool, _) = tool()
        #expect(tool.name == "srv__search")
    }

    @Test func sanitizesNameComponentsForDispatch() {
        let session = FakeMCPSession(
            tools: [MCP.Tool(name: "do thing!", description: "", inputSchema: ["type": "object"])]
        )
        let tool = MCPTool(
            serverName: "my server", toolName: "do thing!", toolDescription: "",
            inputSchema: ["type": "object"], session: session
        )
        #expect(tool.name == "my_server__do_thing_")
    }

    @Test func toolSpecInjectsServerSchemaVerbatim() {
        let (tool, _) = tool()
        let spec = tool.toolSchema()
        let function = spec["function"] as? [String: any Sendable]
        #expect(function?["name"] as? String == "srv__search")
        #expect(function?["description"] as? String == "Search")
        let parameters = function?["parameters"] as? [String: any Sendable]
        #expect(parameters?["type"] as? String == "object")
        let properties = parameters?["properties"] as? [String: any Sendable]
        #expect((properties?["q"] as? [String: any Sendable])?["type"] as? String == "string")
    }

    @Test func executeCallsUnprefixedNameWithConvertedArgs() async throws {
        let (tool, session) = tool()
        let output = try await tool.execute(["q": .string("hi")], ToolContext())
        #expect(output.content == "ok")
        let last = await session.lastCall
        #expect(last?.name == "search")
        #expect(last?.arguments == ["q": .string("hi")])
    }

    @Test func executeThrowsOnIsError() async {
        let (tool, _) = tool(
            result: ([.text(text: "bad input", annotations: nil, _meta: nil)], true)
        )
        await #expect(throws: MCPToolError.self) {
            _ = try await tool.execute(["q": .string("hi")], ToolContext())
        }
    }
}

// MARK: - MultiServerMCPClient

struct MultiServerMCPClientTests {
    private func emptyTool(_ name: String) -> MCP.Tool {
        MCP.Tool(name: name, description: "", inputSchema: ["type": "object"])
    }

    @Test func aggregatesAndPrefixesAcrossServers() async {
        let a = FakeMCPSession(tools: [emptyTool("one")])
        let b = FakeMCPSession(tools: [emptyTool("two")])
        let client = MultiServerMCPClient(
            configs: [
                MCPServerConfig(name: "a", kind: .stdio),
                MCPServerConfig(name: "b", kind: .http, url: "https://example.com/mcp")
            ]
        ) { config in config.name == "a" ? a : b }

        let names = await client.tools().map(\.name)
        #expect(Set(names) == ["a__one", "b__two"])
    }

    @Test func isolatesAFailingServer() async {
        let good = FakeMCPSession(tools: [emptyTool("ok")])
        let bad = FakeMCPSession(tools: [emptyTool("never")], failConnect: true)
        let client = MultiServerMCPClient(
            configs: [
                MCPServerConfig(name: "good", kind: .stdio),
                MCPServerConfig(name: "bad", kind: .stdio)
            ]
        ) { config in config.name == "good" ? good : bad }

        let names = await client.tools().map(\.name)
        #expect(names == ["good__ok"])
    }

    @Test func loadReportsPerServerStatusWithToolCountsAndErrors() async {
        let good = FakeMCPSession(tools: [emptyTool("ok"), emptyTool("ok2")])
        let bad = FakeMCPSession(tools: [emptyTool("never")], failConnect: true)
        let client = MultiServerMCPClient(
            configs: [
                MCPServerConfig(name: "good", kind: .stdio),
                MCPServerConfig(name: "bad", kind: .stdio)
            ]
        ) { config in config.name == "good" ? good : bad }

        let (tools, statuses) = await client.load()
        #expect(tools.map(\.name) == ["good__ok", "good__ok2"]) // the failing server contributes nothing
        let byName = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })
        #expect(byName["good"]?.connected == true)
        #expect(byName["good"]?.toolCount == 2)
        #expect(byName["bad"]?.connected == false) // surfaced, not silently dropped
        #expect(byName["bad"]?.error != nil)
        #expect(byName["bad"]?.toolCount == 0)
    }

    @Test func skipsDisabledServers() async {
        let a = FakeMCPSession(tools: [emptyTool("one")])
        let client = MultiServerMCPClient(
            configs: [MCPServerConfig(name: "a", kind: .stdio, isEnabled: false)]
        ) { _ in a }

        let names = await client.tools().map(\.name)
        #expect(names.isEmpty)
    }

    @Test func disambiguatesCollidingDispatchNames() async {
        // "my server" and "my_server" both sanitize to the same dispatch prefix, so their
        // identically-named tools collide; the later one gets a numeric suffix so both stay
        // reachable.
        let a = FakeMCPSession(tools: [emptyTool("t")])
        let b = FakeMCPSession(tools: [emptyTool("t")])
        let client = MultiServerMCPClient(
            configs: [
                MCPServerConfig(name: "my server", kind: .stdio),
                MCPServerConfig(name: "my_server", kind: .stdio)
            ]
        ) { config in config.name == "my server" ? a : b }

        let names = await client.tools().map(\.name)
        #expect(names == ["my_server__t", "my_server__t_2"])
    }
}
