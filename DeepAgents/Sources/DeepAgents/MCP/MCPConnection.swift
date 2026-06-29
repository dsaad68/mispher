import Foundation
import MCP
import System

/// A live connection to one MCP server — Mispher's analogue of an `mcp` `ClientSession`.
/// Behind a protocol so the tool-loading layer (`MultiServerMCPClient`, `MCPTool`) can be
/// unit-tested with an in-memory fake, exactly as the agent tests use `FakeChatModel`.
///
/// A session is **persistent**: opened once and reused across tool calls (suited to local
/// stdio servers that may hold state), then torn down via `disconnect`.
protocol MCPSession: Sendable {
    /// Open the transport and run the MCP initialize handshake. Idempotent.
    func connect() async throws
    /// The tools the server advertises (paginated cursors followed internally).
    func listTools() async throws -> [Tool]
    /// Invoke a tool by its **server-side** name (unprefixed).
    func callTool(
        name: String, arguments: [String: Value]?
    ) async throws -> (content: [Tool.Content], isError: Bool?)
    /// Close the connection and reap any launched subprocess.
    func disconnect() async
}

enum MCPClientError: LocalizedError {
    case invalidURL(String)
    case emptyCommand(server: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid MCP server URL: \(url)"
        case .emptyCommand(let server):
            return "MCP server '\(server)' has no command configured."
        }
    }
}

/// An `MCPSession` backed by the official `modelcontextprotocol/swift-sdk` `Client`.
///
/// `stdio` servers are launched here as a subprocess (the SDK's `StdioTransport` only
/// wraps file descriptors — it does not spawn processes), wiring the child's stdin/stdout
/// to the transport via a pair of pipes. This mirrors the app's existing subprocess
/// supervision in `LlamaServerManager`. `http` servers connect over `HTTPClientTransport`
/// with the configured headers applied per request.
public actor SwiftSDKMCPSession: MCPSession {
    private let config: MCPServerConfig
    private let client: Client
    /// Browser opener for the OAuth sign-in flow, injected so the framework carries no
    /// UI-framework dependency. Defaults to a no-op (no browser) when a caller omits it.
    private let openURL: @Sendable (URL) -> Void
    /// The "Signed in" page served on the OAuth loopback callback, so each front-end can carry its
    /// own branding. Defaults to the Mispher page, so existing callers are unchanged.
    private let successHTML: String
    /// Force-attach the OAuth authorizer even when the config carries no `oauth` key - used to drive a
    /// sign-in against a plain HTTP server whose auth requirement was discovered from a 401 (the way
    /// Claude Code treats every HTTP server), rather than declared up front. See ``makeTransport``.
    private let requireOAuth: Bool
    private var process: Process?
    /// The file handle the child's stderr is logged to (stdio transport); closed on
    /// teardown so we don't leak a descriptor.
    private var errorLogHandle: FileHandle?
    private var connected = false

    public init(
        config: MCPServerConfig, openURL: @escaping @Sendable (URL) -> Void = { _ in },
        successHTML: String = MCPOAuthSuccessPage.mispher, requireOAuth: Bool = false
    ) {
        self.config = config
        self.openURL = openURL
        self.successHTML = successHTML
        self.requireOAuth = requireOAuth
        client = Client(name: DeepAgentsIdentity.productName, version: "1.0.0")
    }

    public func connect() async throws {
        guard !connected else { return }
        let transport = try makeTransport()
        do {
            try await client.connect(transport: transport)
        } catch {
            // The transport may have launched a subprocess (stdio); reap it so a failed
            // handshake doesn't leak the child process or its log handle.
            cleanupProcess()
            throw error
        }
        connected = true
    }

    public func listTools() async throws -> [Tool] {
        var all: [Tool] = []
        var cursor: String?
        repeat {
            let (tools, next) = try await client.listTools(cursor: cursor)
            all += tools
            cursor = next
        } while cursor != nil
        return all
    }

    func callTool(
        name: String, arguments: [String: Value]?
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        try await client.callTool(name: name, arguments: arguments)
    }

    public func disconnect() async {
        await client.disconnect()
        cleanupProcess()
        connected = false
    }

    /// Terminate any launched subprocess and close its stderr log handle.
    private func cleanupProcess() {
        process?.terminate()
        process = nil
        try? errorLogHandle?.close()
        errorLogHandle = nil
    }

    // MARK: - Transport construction

    private func makeTransport() throws -> any Transport {
        switch config.kind {
        case .http:
            guard let url = URL(string: config.url), url.scheme != nil else {
                throw MCPClientError.invalidURL(config.url)
            }
            let headers = config.headers
            // Attach the SDK's OAuth authorizer - which acquires (and refreshes) a Bearer token via the
            // browser sign-in flow, on top of any static headers - when the server is declared `oauth`,
            // when the caller forces it (an explicit sign-in against a server whose auth was discovered
            // from a 401), or when we already hold a Keychain token for it (so a server signed in once
            // reconnects silently, even without an `oauth` key). The authorizer is lazy: it only runs
            // the browser flow on a 401, so attaching it never opens a browser while a token is valid.
            let attachOAuth = config.auth == .oauth || requireOAuth
                || KeychainTokenStorage(serverID: config.id.uuidString).hasToken
            let authorizer: (any HTTPClientAuthorizer)? =
                attachOAuth
                    ? makeMCPOAuthAuthorizer(for: config, openURL: openURL, successHTML: successHTML) : nil
            return HTTPClientTransport(
                endpoint: url,
                streaming: true,
                authorizer: authorizer,
                requestModifier: { request in
                    var request = request
                    for (field, value) in headers {
                        request.setValue(value, forHTTPHeaderField: field)
                    }
                    return request
                }
            )
        case .stdio:
            return try makeStdioTransport()
        }
    }

    /// Launch the configured command and connect its stdio to a `StdioTransport`.
    /// `inPipe` carries client → server (the child's stdin); `outPipe` carries
    /// server → client (the child's stdout); `stderr` is redirected to a per-server log
    /// file (or discarded if it can't be opened).
    private func makeStdioTransport() throws -> any Transport {
        let command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw MCPClientError.emptyCommand(server: config.name) }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let process = Process()

        // Absolute path → launch directly; bare name → resolve through `/usr/bin/env`
        // against the inherited (and config-augmented) PATH.
        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = config.args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + config.args
        }

        if !config.env.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in config.env { environment[key] = value }
            process.environment = environment
        }

        process.standardInput = inPipe
        process.standardOutput = outPipe
        // Capture the child's stderr — where MCP servers emit startup/handshake errors and
        // diagnostics — to a per-server log file (mirrors `LlamaServerManager`), so tool-load
        // failures are debuggable. Fall back to discarding it if the file can't be opened.
        // The handle is retained so `cleanupProcess()` can close it (avoids a leaked fd).
        let logPath = "\(NSTemporaryDirectory())mispher-mcp-\(MCPTool.sanitize(config.name)).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let errorHandle = FileHandle(forWritingAtPath: logPath)
        process.standardError = errorHandle ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? errorHandle?.close()
            throw error
        }
        self.process = process
        errorLogHandle = errorHandle

        // Close the ends the parent doesn't use. In particular, the parent's copy of the
        // child's stdout writer (`outPipe.fileHandleForWriting`) must be closed, or the read
        // side never sees EOF when the child exits (the parent itself would still be a
        // writer). The child keeps its own inherited copies.
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()

        let input = FileDescriptor(rawValue: outPipe.fileHandleForReading.fileDescriptor)
        let output = FileDescriptor(rawValue: inPipe.fileHandleForWriting.fileDescriptor)
        return StdioTransport(input: input, output: output)
    }
}
