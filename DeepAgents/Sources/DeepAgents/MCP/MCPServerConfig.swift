import Foundation

/// A configured MCP server — Mispher's analogue of one entry in
/// `langchain-mcp-adapters`' `MultiServerMCPClient` connections map. `Codable` so a list
/// of these round-trips through `UserDefaults` as JSON (the pattern the app already uses
/// for hotkeys), and `Identifiable` for SwiftUI list editing.
///
/// A flat shape (rather than an enum with associated values) keeps the Settings form and
/// the stored JSON simple: `kind` selects which fields are meaningful — `command`/`args`/
/// `env` for `.stdio`, `url`/`headers` for `.http`.
public struct MCPServerConfig: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A local server launched as a subprocess; the client talks to it over its
        /// stdin/stdout (the MCP stdio transport).
        case stdio
        /// A remote server reached over HTTP (with optional SSE streaming).
        case http
    }

    /// How an `http` server authenticates. `none` uses the configured `headers` verbatim
    /// (including a static `Authorization: Bearer <api-key>` if the user adds one); `oauth`
    /// runs the SDK's OAuth 2.1 authorization-code flow, opening a browser to sign in and
    /// caching the token in the Keychain.
    public enum Auth: String, Codable, Sendable, CaseIterable {
        case none
        case oauth
    }

    public var id: UUID = .init()
    /// Logical name; also the prefix in every tool this server contributes (`name__tool`),
    /// so tools from different servers never collide.
    public var name: String
    public var kind: Kind
    /// Whether this server participates when the client loads tools.
    public var isEnabled: Bool = true

    // stdio
    /// Executable to launch — an absolute path, or a bare name resolved via `PATH`.
    public var command: String = ""
    public var args: [String] = []
    /// Extra environment variables, merged over the process's inherited environment.
    public var env: [String: String] = [:]

    // http
    public var url: String = ""
    public var headers: [String: String] = [:]
    /// How an `http` server authenticates (header-only `none`, or browser `oauth`).
    public var auth: Auth = .none

    /// How the agent gates this server's tools: run them (`approve`), ask the user every time
    /// (`ask`, the default - MCP tools are outward-facing), or always reject (`deny`).
    public var approvalMode: ToolApprovalMode = .ask

    public init(
        id: UUID = .init(), name: String, kind: Kind, isEnabled: Bool = true,
        command: String = "", args: [String] = [], env: [String: String] = [:],
        url: String = "", headers: [String: String] = [:], auth: Auth = .none,
        approvalMode: ToolApprovalMode = .ask
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.auth = auth
        self.approvalMode = approvalMode
    }

    /// Tolerant decoding: any field missing from older stored JSON falls back to its default, so
    /// adding fields (like `approvalMode`) never makes a saved server fail to decode - which,
    /// because the loader uses `try?`, would silently drop every configured server.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? .init()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .stdio
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        auth = try container.decodeIfPresent(Auth.self, forKey: .auth) ?? .none
        approvalMode = try container.decodeIfPresent(ToolApprovalMode.self, forKey: .approvalMode) ?? .ask
    }
}
