import Foundation

/// Shell middleware - one general-purpose `shell` tool that runs a command line in the working
/// folder via `/bin/sh -c`. Unlike the read-only wrappers (`git_*`, `grep`, `head`, …), this is
/// unrestricted command execution, so it is gated two ways: ``ShellGuard`` hard-blocks
/// catastrophic commands, and every other command is shown to the user behind the (red)
/// approval card before it runs. Registered only on the real-disk path (when an approval
/// handler exists), like the other system-touching middleware.
public struct ShellToolsMiddleware: AgentMiddleware {
    let root: WorkspaceRoot

    public init(root: WorkspaceRoot) { self.root = root }

    public var name: String { "shell" }
    public var tools: [any AgentTool] { [ShellTool(root: root)] }

    /// Hard-block catastrophic commands before they reach the approval card. This runs outside the
    /// human-in-the-loop middleware, so a blocked command never prompts; throwing (rather than
    /// returning a tool message) makes the loop render it as a failed, red step and feed the model
    /// a clear "blocked by policy" error instead of the "user rejected" wording.
    public func wrapToolCall(
        _ request: ToolCallRequest,
        _ handler: (ToolCallRequest) async throws -> AgentMessage
    ) async throws -> AgentMessage {
        if request.call.name == "shell",
           case .string(let command)? = request.call.arguments["command"],
           case .blocked(let reason) = ShellGuard.classify(command) {
            throw ShellBlockedError(reason: reason)
        }
        return try await handler(request)
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
    ## Shell with `shell`
    Run a command line in your working folder with `shell` (executed via `/bin/sh -c`) - use it \
    for work the dedicated tools don't cover (building, running scripts, moving files, …). The \
    user is shown every command and approves it before it runs, so send one clear command at a \
    time. Some catastrophic commands are always blocked (privilege escalation like `sudo`, disk \
    formatting/erasing, recursive deletes of system paths, piping a download into a shell) - \
    don't attempt those; do the work a safer way.
    """
}

/// The shared shape of a shell-block message, so both block paths phrase it the same way and the
/// chat renderer can recognize a blocked result and pull the bare reason back out for its red
/// BLOCKED badge.
public enum ShellBlock {
    public static let prefix = "Blocked by the shell safety policy and not run: "
    public static let suffix = " Do not retry it; take a safer approach."

    /// The full model-facing message for a blocked command.
    public static func message(_ reason: String) -> String { prefix + reason + suffix }

    /// The bare reason inside a blocked-shell result string (the raw `{"error":"…"}` the model
    /// sees, or the message itself), or nil when `text` isn't a shell block.
    public static func reason(in text: String) -> String? {
        guard let start = text.range(of: prefix) else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.range(of: suffix)?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }
}

/// A `shell` command ``ShellGuard`` refused. Thrown from ``ShellToolsMiddleware`` so the loop
/// renders it as a failed (red) tool step and feeds the model a clear "blocked by policy" error -
/// never "user rejected", since the user was never asked.
struct ShellBlockedError: LocalizedError {
    let reason: String
    var errorDescription: String? { ShellBlock.message(reason) }
}

/// `shell`: run a command line via `/bin/sh -c` in the working folder and return its output.
public struct ShellTool: AgentTool {
    let root: WorkspaceRoot

    public var name: String { "shell" }
    public var description: String {
        "Run a shell command in the working folder (via /bin/sh -c) and return its combined "
            + "output. Use for command-line work the other tools don't cover. Dangerous commands "
            + "are blocked, and the user approves every command before it runs."
    }

    public var parameters: [ToolParameter] {
        [
            .required(
                "command", type: .string,
                description: "The shell command to run, e.g. \"swift build\" or \"ls -la src\"."
            ),
            .optional(
                "stdin", type: .string,
                description: "Text to feed to the command on standard input."
            ),
            .optional(
                "timeout", type: .int,
                description: "Seconds before the command is killed (default \(Self.defaultTimeout), max \(Self.maxTimeout))."
            )
        ]
    }

    static let defaultTimeout = 60
    static let maxTimeout = 900

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let command = ToolArgs.rawString(arguments, "command"),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return ToolOutput("Error: `command` is required.") }

        // Backstop: re-check at execution time so the block also holds for a command the user
        // edited to something dangerous in the approval card (the middleware classified the
        // original, pre-edit command).
        if case .blocked(let reason) = ShellGuard.classify(command) {
            return ToolOutput(ReactAgent.errorJSON(ShellBlock.message(reason)))
        }

        let seconds = min(Self.maxTimeout, max(1, ToolArgs.int(arguments, "timeout") ?? Self.defaultTimeout))
        do {
            // Stream stdout/stderr live as `.toolProgress` so a long command shows progress; the
            // loop replaces it with the formatted result (`toolCompleted`) when the tool returns.
            let result = try await ProcessRunner.run(
                "/bin/sh", ["-c", command], cwd: root.rootURL,
                stdin: ToolArgs.rawString(arguments, "stdin"), timeout: TimeInterval(seconds),
                onOutput: { context.onEvent(.toolProgress(name: "shell", subagent: nil, delta: $0)) }
            )
            return ToolOutput(Self.format(result, timeout: seconds))
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }

    /// Combine stdout and stderr into one model-facing block, noting a non-zero exit or a kill.
    static func format(_ result: ProcessRunner.Result, timeout: Int) -> String {
        var body = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        if result.timedOut {
            body += (body.isEmpty ? "" : "\n") + "[Command timed out after \(timeout)s and was killed.]"
        } else if result.status != 0 {
            body += (body.isEmpty ? "" : "\n") + "[Exited with status \(result.status).]"
        }
        return body.isEmpty ? "(no output)" : body
    }
}
