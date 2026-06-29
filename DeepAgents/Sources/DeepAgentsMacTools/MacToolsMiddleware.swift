import DeepAgents
import Foundation

/// System (macOS) middleware - `mdfind` (Spotlight search), `open` / `open_app` (hand a file
/// or URL to the OS), `download` (save a URL to disk), `say` (text-to-speech), and `notify`
/// (post a notification). Outward-facing actions; `download` stays inside the working folder,
/// and `mdfind` can search the whole Mac unless scoped with `path`.
public struct MacToolsMiddleware: AgentMiddleware {
    let root: WorkspaceRoot
    let client: any HTTPClient

    public init(root: WorkspaceRoot, client: any HTTPClient = URLSessionHTTPClient()) {
        self.root = root
        self.client = client
    }

    public var name: String { "macos" }
    public var tools: [any AgentTool] {
        [
            SpotlightTool(root: root), OpenTool(root: root), OpenAppTool(root: root),
            DownloadTool(root: root, client: client), SayTool(), NotifyTool()
        ]
    }

    public func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        let composed = [request.systemPrompt, Self.systemPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return try await handler(request.override(systemPrompt: composed))
    }

    public static let systemPrompt = """
    ## macOS with `mdfind` / `open` / `open_app` / `download` / `say` / `notify`
    Use `mdfind` (Spotlight) to find files anywhere on the Mac, `open` to open a file or URL \
    in its default app, `open_app` to launch an app (optionally with a file or URL), \
    `download` to save a URL to a file in your working folder, `say` to speak text aloud, and \
    `notify` to post a notification.
    """
}

/// `mdfind`: Spotlight search returning matching file paths.
public struct SpotlightTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "mdfind" }
    public var description: String {
        "Search the Mac with Spotlight and return matching file paths. "
            + "Searches the whole Mac unless you pass path to scope it."
    }

    public var parameters: [ToolParameter] {
        [
            .required("query", type: .string, description: "Spotlight query (a filename or words in a document)."),
            .optional("path", type: .string, description: "Limit the search to this folder (inside your working folder).")
        ]
    }

    static let maxResults = 100

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let query = ToolArgs.string(arguments, "query") else { return ToolOutput("Error: `query` is required.") }
        guard !ToolArgs.looksLikeOption(query) else { return ToolOutput("Error: the query can't start with \"-\".") }
        var args: [String] = []
        if let path = ToolArgs.string(arguments, "path") {
            guard let url = try? root.resolve(path) else {
                return ToolOutput("Error: \"\(path)\" is outside the working folder.")
            }
            args += ["-onlyin", url.path]
        }
        args.append(query)
        do {
            let result = try await ProcessRunner.run("/usr/bin/mdfind", args)
            if result.timedOut { return ToolOutput("Error: mdfind timed out.") }
            let lines = result.stdout.split(separator: "\n").prefix(Self.maxResults)
            return lines.isEmpty
                ? ToolOutput("No files matched \"\(query)\".")
                : ToolOutput(lines.joined(separator: "\n"))
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// `open`: open a file or URL in its default macOS app.
public struct OpenTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "open" }
    public var description: String { "Open a file or URL in its default macOS app." }

    public var parameters: [ToolParameter] {
        [.required("target", type: .string, description: "A URL (http/https/mailto/…) or a file path inside your working folder.")]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let target = ToolArgs.string(arguments, "target") else { return ToolOutput("Error: `target` is required.") }
        guard !ToolArgs.looksLikeOption(target) else { return ToolOutput("Error: the target can't start with \"-\".") }
        let argument: String
        do { argument = try MacTools.resolveTarget(target, root: root) } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
        return await ToolOutput(MacTools.open([argument], success: "Opened \(target)."))
    }
}

/// `open_app`: launch an app by name, optionally with a file or URL.
public struct OpenAppTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "open_app" }
    public var description: String { "Launch a macOS app by name, optionally opening a file or URL with it." }

    public var parameters: [ToolParameter] {
        [
            .required("app", type: .string, description: "App name, e.g. Safari or Notes."),
            .optional("target", type: .string, description: "A file (inside your working folder) or URL to open with the app.")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let app = ToolArgs.string(arguments, "app") else { return ToolOutput("Error: `app` is required.") }
        guard !ToolArgs.looksLikeOption(app) else { return ToolOutput("Error: the app name can't start with \"-\".") }
        var args = ["-a", app]
        if let target = ToolArgs.string(arguments, "target") {
            guard !ToolArgs.looksLikeOption(target) else { return ToolOutput("Error: the target can't start with \"-\".") }
            do { try args.append(MacTools.resolveTarget(target, root: root)) } catch {
                return ToolOutput("Error: \(error.localizedDescription)")
            }
        }
        return await ToolOutput(MacTools.open(args, success: "Launched \(app)."))
    }
}

/// `download`: save a URL to a file inside the working folder.
public struct DownloadTool: AgentTool {
    let root: WorkspaceRoot
    let client: any HTTPClient
    public var name: String { "download" }
    public var description: String { "Download a URL to a file inside your working folder." }

    public var parameters: [ToolParameter] {
        [
            .required("url", type: .string, description: "The http(s) URL to download."),
            .required("path", type: .string, description: "Destination file path inside your working folder.")
        ]
    }

    static let maxBytes = 50_000_000

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let rawURL = ToolArgs.string(arguments, "url"), let url = WebTools.url(from: rawURL) else {
            return ToolOutput("Error: a valid http(s) `url` is required.")
        }
        guard let rawPath = ToolArgs.string(arguments, "path") else { return ToolOutput("Error: `path` is required.") }
        let dest: URL
        do { dest = try root.resolve(rawPath) } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
        do {
            let response = try await client.send(HTTPRequest(url: url, timeout: 120))
            guard (200 ..< 300).contains(response.statusCode) else {
                return ToolOutput("Error: \(url.absoluteString) returned status \(response.statusCode).")
            }
            guard response.body.count <= Self.maxBytes else {
                return ToolOutput("Error: the file is too large (\(response.body.count) bytes; limit \(Self.maxBytes)).")
            }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try response.body.write(to: dest, options: .atomic)
            return ToolOutput("Saved \(response.body.count) bytes to \"\(root.relativePath(dest))\".")
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// `say`: speak text aloud through macOS text-to-speech.
public struct SayTool: AgentTool {
    public var name: String { "say" }
    public var description: String { "Speak text aloud through the Mac's text-to-speech." }

    public var parameters: [ToolParameter] {
        [
            .required("text", type: .string, description: "What to say."),
            .optional("voice", type: .string, description: "A system voice name, e.g. Samantha.")
        ]
    }

    static let maxChars = 1000

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let text = ToolArgs.string(arguments, "text") else { return ToolOutput("Error: `text` is required.") }
        var args: [String] = []
        if let voice = ToolArgs.string(arguments, "voice") {
            guard !ToolArgs.looksLikeOption(voice) else { return ToolOutput("Error: invalid voice name.") }
            args += ["-v", voice]
        }
        // `--` so text starting with "-" isn't parsed as an option.
        args += ["--", String(text.prefix(Self.maxChars))]
        do {
            let result = try await ProcessRunner.run("/usr/bin/say", args, timeout: 60)
            if result.timedOut { return ToolOutput("Spoke the text (cut off after 60s).") }
            return result.succeeded
                ? ToolOutput("Spoke the text aloud.")
                : ToolOutput("Error: \(result.stderr.isEmpty ? "say failed." : result.stderr)")
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// `notify`: post a macOS notification (via `osascript`, arguments passed as argv).
public struct NotifyTool: AgentTool {
    public var name: String { "notify" }
    public var description: String { "Post a macOS notification." }

    public var parameters: [ToolParameter] {
        [
            .required("title", type: .string, description: "Notification title."),
            .optional("message", type: .string, description: "Notification body text.")
        ]
    }

    static let script = """
    on run argv
        display notification (item 2 of argv) with title (item 1 of argv)
    end run
    """

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let title = ToolArgs.string(arguments, "title") else { return ToolOutput("Error: `title` is required.") }
        let message = ToolArgs.string(arguments, "message") ?? ""
        do {
            let result = try await ProcessRunner.run(
                "/usr/bin/osascript", ["-", title, message], stdin: Self.script
            )
            if result.timedOut { return ToolOutput("Error: notify timed out.") }
            return result.succeeded
                ? ToolOutput("Posted a notification titled \"\(title)\".")
                : ToolOutput("Error: \(result.stderr.isEmpty ? "couldn't post the notification." : result.stderr)")
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// Shared helpers for the system tools.
enum MacTools {
    /// Turn a model-supplied target into an argument for `open`: a URL passes through, a path
    /// is resolved inside the working folder (throwing ``WorkspaceRootError`` if it escapes).
    static func resolveTarget(_ target: String, root: WorkspaceRoot) throws -> String {
        if let scheme = URL(string: target)?.scheme, !scheme.isEmpty, !target.hasPrefix("/") {
            return target // a URL like https://… or mailto:…
        }
        return try root.resolve(target).path
    }

    /// Run `/usr/bin/open` with `arguments`, returning `success` or an "Error: …" message.
    static func open(_ arguments: [String], success: String) async -> String {
        do {
            let result = try await ProcessRunner.run("/usr/bin/open", arguments)
            if result.timedOut { return "Error: open timed out." }
            return result.succeeded
                ? success
                : "Error: \(result.stderr.isEmpty ? "open exited with status \(result.status)." : result.stderr)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
