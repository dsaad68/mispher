import Foundation

/// Git middleware - read-only inspection of the repository in the working folder:
/// `git_status`, `git_diff`, `git_log`, `git_show`, `git_blame`. Every tool runs
/// `git -C <root> …` and never commits, pushes, or mutates the repo.
public struct GitToolsMiddleware: AgentMiddleware {
    let root: WorkspaceRoot

    public init(root: WorkspaceRoot) { self.root = root }

    public var name: String { "git" }
    public var tools: [any AgentTool] {
        [
            GitStatusTool(root: root), GitDiffTool(root: root), GitLogTool(root: root),
            GitShowTool(root: root), GitBlameTool(root: root)
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
    ## Git (read-only) with `git_status` / `git_diff` / `git_log` / `git_show` / `git_blame`
    Inspect the git repository in your working folder: `git_status` for the working-tree \
    state, `git_diff` for unstaged (or staged) changes, `git_log` for recent commits, \
    `git_show` for one commit, and `git_blame` for line-by-line authorship. These only read \
    the repo - they never commit, push, or change anything.
    """
}

/// `git_status`: branch and changed files in the working tree.
public struct GitStatusTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "git_status" }
    public var description: String { "Show the git working-tree status (branch and changed files)." }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        await ToolOutput(GitTools.run(root, ["status", "--short", "--branch"]))
    }
}

/// `git_diff`: unstaged (or staged) changes, optionally limited to one path.
public struct GitDiffTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "git_diff" }
    public var description: String {
        "Show git changes as a diff. Set staged to see staged changes; pass path to limit to one file or folder."
    }

    public var parameters: [ToolParameter] {
        [
            .optional("staged", type: .bool, description: "Show staged (index) changes instead of unstaged."),
            .optional("path", type: .string, description: "Limit the diff to this file or folder.")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        var args = ["diff"]
        if ToolArgs.bool(arguments, "staged") { args.append("--staged") }
        if let path = ToolArgs.string(arguments, "path") {
            guard let url = try? root.resolve(path) else {
                return ToolOutput("Error: \"\(path)\" is outside the working folder.")
            }
            args += ["--", url.path]
        }
        return await ToolOutput(GitTools.run(root, args))
    }
}

/// `git_log`: recent commits in one-line form.
public struct GitLogTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "git_log" }
    public var description: String { "Show recent commits (one line each)." }

    public var parameters: [ToolParameter] {
        [
            .optional("count", type: .int, description: "How many recent commits (default 20)."),
            .optional("path", type: .string, description: "Limit history to this file or folder.")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        let count = min(max(1, ToolArgs.int(arguments, "count") ?? 20), 200)
        var args = ["log", "--oneline", "-n", String(count)]
        if let path = ToolArgs.string(arguments, "path") {
            guard let url = try? root.resolve(path) else {
                return ToolOutput("Error: \"\(path)\" is outside the working folder.")
            }
            args += ["--", url.path]
        }
        return await ToolOutput(GitTools.run(root, args))
    }
}

/// `git_show`: a single commit (message + patch).
public struct GitShowTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "git_show" }
    public var description: String { "Show one commit: its message and the changes it made." }

    public var parameters: [ToolParameter] {
        [.optional("ref", type: .string, description: "Commit, tag, or ref to show (default HEAD).")]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        let ref = ToolArgs.string(arguments, "ref") ?? "HEAD"
        guard !ToolArgs.looksLikeOption(ref) else { return ToolOutput("Error: invalid ref \"\(ref)\".") }
        return await ToolOutput(GitTools.run(root, ["show", ref]))
    }
}

/// `git_blame`: line-by-line authorship for a file.
public struct GitBlameTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "git_blame" }
    public var description: String { "Show line-by-line authorship (last commit per line) for a file." }

    public var parameters: [ToolParameter] {
        [.required("path", type: .string, description: "File to annotate.")]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let path = ToolArgs.string(arguments, "path") else { return ToolOutput("Error: `path` is required.") }
        guard let url = try? root.resolve(path) else {
            return ToolOutput("Error: \"\(path)\" is outside the working folder.")
        }
        return await ToolOutput(GitTools.run(root, ["blame", "--", url.path]))
    }
}

/// Run a read-only git subcommand in `root`, returning model-ready output or an "Error: …"
/// string (with a clean message when the folder isn't a repository).
enum GitTools {
    static func run(_ root: WorkspaceRoot, _ arguments: [String]) async -> String {
        do {
            let result = try await ProcessRunner.run(
                "/usr/bin/git", ["-C", root.rootURL.path] + arguments, cwd: root.rootURL
            )
            if result.timedOut { return "Error: git timed out." }
            if result.succeeded { return result.stdout.isEmpty ? "(no output)" : result.stdout }
            if result.stderr.lowercased().contains("not a git repository") {
                return "Error: \(root.displayRoot) is not a git repository."
            }
            return "Error: \(result.stderr.isEmpty ? "git exited with status \(result.status)." : result.stderr)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
