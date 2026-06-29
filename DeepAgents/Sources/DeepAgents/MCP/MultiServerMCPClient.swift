import Foundation
import MCP
import OSLog

/// Connects to a set of named MCP servers and aggregates their tools into one flat
/// `[any AgentTool]` for an agent — Mispher's port of `langchain-mcp-adapters`'
/// `MultiServerMCPClient.get_tools()`.
///
/// This is the reusable seam: build one from the user's configured servers, `await
/// tools()`, and hand the result to `createAgent(tools:)` / `createDeepAgent(tools:)`, or
/// wrap it in an ``MCPMiddleware``. Sessions are opened lazily on the first `tools()` call
/// and reused; one server failing to connect or list is isolated (logged and skipped) so
/// it can't sink the rest.
///
/// `makeSession` is injectable so tests can substitute an in-memory `MCPSession` (the same
/// pattern as `FakeChatModel`); it defaults to a real `SwiftSDKMCPSession`.
public actor MultiServerMCPClient {
    private let configs: [MCPServerConfig]
    private let makeSession: @Sendable (MCPServerConfig) -> any MCPSession
    private var sessions: [UUID: any MCPSession] = [:]

    private static let log = Logger(subsystem: "Mispher", category: "MCP")

    /// Build a client that talks to each configured server with a real ``SwiftSDKMCPSession``
    /// (stdio subprocess or http transport).
    public init(
        configs: [MCPServerConfig], openURL: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.configs = configs
        makeSession = { SwiftSDKMCPSession(config: $0, openURL: openURL) }
    }

    /// Testing initializer: inject an in-memory ``MCPSession`` factory (the `FakeChatModel`
    /// pattern). Internal because ``MCPSession`` is an internal protocol.
    init(
        configs: [MCPServerConfig],
        makeSession: @escaping @Sendable (MCPServerConfig) -> any MCPSession
    ) {
        self.configs = configs
        self.makeSession = makeSession
    }

    /// Connect (if needed) to every enabled server and return all their tools, each
    /// namespaced `server__tool`. Per-server failures are logged and skipped. (Thin wrapper over
    /// ``load()`` for callers that only want the tools.)
    public func tools() async -> [any AgentTool] { await load().tools }

    /// Connect (if needed) to every enabled server, returning all their tools (each namespaced
    /// `server__tool`) together with a per-server ``MCPServerStatus`` - the tool count on success,
    /// or the connect/list error. A failure is isolated (logged, recorded in its status, and
    /// skipped) so one server can't sink the rest; the status lets a UI show *why* a server
    /// contributed nothing instead of a blank "0 tools".
    public func load() async -> (tools: [any AgentTool], statuses: [MCPServerStatus]) {
        var result: [any AgentTool] = []
        var statuses: [MCPServerStatus] = []
        var seen: Set<String> = []
        for config in configs where config.isEnabled {
            do {
                let session = try await session(for: config)
                let mcpTools = try await session.listTools()
                var contributed = 0
                for tool in mcpTools {
                    var agentTool = MCPTool(
                        serverName: config.name,
                        toolName: tool.name,
                        toolDescription: tool.description ?? "",
                        inputSchema: tool.inputSchema,
                        session: session
                    )
                    // Two tools can sanitize to the same dispatch name (e.g. servers
                    // "my server"/"my_server"), and ReactAgent dispatches by exact name. Rather
                    // than drop the later one, disambiguate it with a numeric suffix so every
                    // tool stays reachable and dispatch is deterministic.
                    let baseName = agentTool.name
                    if seen.contains(baseName) {
                        var suffix = 2
                        while seen.contains("\(baseName)_\(suffix)") { suffix += 1 }
                        let unique = "\(baseName)_\(suffix)"
                        agentTool.nameOverride = unique
                        Self.log.notice(
                            // swiftlint:disable:next line_length
                            "MCP tool dispatch-name collision on '\(baseName, privacy: .public)' (server '\(config.name, privacy: .public)'); exposing it as '\(unique, privacy: .public)'."
                        )
                    }
                    seen.insert(agentTool.name)
                    result.append(agentTool)
                    contributed += 1
                }
                statuses.append(MCPServerStatus(id: config.id, name: config.name, toolCount: contributed, error: nil))
            } catch {
                Self.log.error(
                    "MCP server '\(config.name, privacy: .public)' unavailable: \(error.localizedDescription, privacy: .private)"
                )
                statuses.append(MCPServerStatus(
                    id: config.id, name: config.name, toolCount: 0, error: error.localizedDescription
                ))
            }
        }
        return (result, statuses)
    }

    /// Close every open session and reap any launched subprocesses.
    public func disconnectAll() async {
        for session in sessions.values { await session.disconnect() }
        sessions.removeAll()
    }

    private func session(for config: MCPServerConfig) async throws -> any MCPSession {
        if let existing = sessions[config.id] { return existing }
        let session = makeSession(config)
        try await session.connect()
        sessions[config.id] = session
        return session
    }
}

/// Contributes a precomputed set of MCP tools to an agent through the middleware system —
/// the same way `ClipboardMiddleware` etc. contribute tools.
///
/// Because `AgentMiddleware.tools` is synchronous while loading MCP tools is async, await
/// `MultiServerMCPClient.tools()` up front and hand the result here:
///
/// ```swift
/// let client = MultiServerMCPClient(configs: configs)
/// let agent = createDeepAgent(model: model, middleware: [MCPMiddleware(tools: await client.tools())])
/// ```
public struct MCPMiddleware: AgentMiddleware {
    public var name: String { "mcp" }
    private let mcpTools: [any AgentTool]

    public init(tools: [any AgentTool]) { mcpTools = tools }

    public var tools: [any AgentTool] { mcpTools }
}

/// Map each loaded MCP tool to its server's approval mode, to pass as
/// `MispherDeepAgent.make(mcpApprovalDefaults:)`. Tools are namespaced `server__tool`, so each is
/// attributed to the server whose dispatch-name prefix it carries. Shared by the app and ripple.
public func mcpApprovalDefaults(
    servers: [MCPServerConfig], tools: [any AgentTool]
) -> [String: ToolApprovalMode] {
    var defaults: [String: ToolApprovalMode] = [:]
    for server in servers {
        let prefix = MCPTool.dispatchPrefix(forServer: server.name)
        for tool in tools where tool.name.hasPrefix(prefix) {
            defaults[tool.name] = server.approvalMode
        }
    }
    return defaults
}

/// The outcome of connecting to one MCP server: how many tools it contributed, or the error that
/// kept it from loading (a 401, a bad URL, a missing stdio binary). Lets the REPL banner and the
/// `/mcp` browser report a server that failed to connect, instead of showing it as a blank
/// "0 tools". Keyed by the server's stable id.
public struct MCPServerStatus: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let toolCount: Int
    public let error: String?
    public var connected: Bool { error == nil }

    public init(id: UUID, name: String, toolCount: Int, error: String?) {
        self.id = id
        self.name = name
        self.toolCount = toolCount
        self.error = error
    }
}

/// One MCP tool projected for display: its short name (the dispatch name minus the `server__`
/// prefix), the full namespaced dispatch name, the description, and the input JSON Schema.
public struct MCPToolDisplay: Sendable {
    public let name: String
    public let dispatchName: String
    public let description: String
    public let schema: [String: any Sendable]
}

/// The tools `tools` contributed by `serverName`, attributed by the namespaced `server__tool`
/// dispatch prefix and projected for display. Lets a UI reflect the agent's live (warm) MCP
/// tool set per server without re-parsing the agent's internal tool types.
public func mcpToolsForDisplay(server serverName: String, in tools: [any AgentTool]) -> [MCPToolDisplay] {
    let prefix = MCPTool.dispatchPrefix(forServer: serverName)
    return tools.filter { $0.name.hasPrefix(prefix) }.map { tool in
        let spec = tool.toolSchema()
        let schema = (spec["function"] as? [String: any Sendable])?["parameters"] as? [String: any Sendable] ?? [:]
        return MCPToolDisplay(
            name: String(tool.name.dropFirst(prefix.count)),
            dispatchName: tool.name,
            description: tool.description,
            schema: schema
        )
    }
}
