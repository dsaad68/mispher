import Foundation

/// Container middleware - a `container_shell` tool that runs a command inside an Apple Container
/// sandbox (``AppleContainerSandbox``) with the working folder mounted at `/workspace`, instead of
/// on the user's Mac. It sits alongside the local `shell` tool (``ShellToolsMiddleware``): the agent
/// picks `container_shell` for isolated work (building, running code, installing packages) and the
/// plain `shell` for things that must touch the real system.
///
/// This mirrors deepagents' sandbox-backend model: the middleware exposes the execution tool and
/// routes it to a swappable backend. Like the local shell it's gated two ways - ``ShellGuard``
/// hard-blocks catastrophic commands (the host folder is mounted, so a stray `rm -rf /workspace`
/// still matters), and every other command is shown to the user behind the approval card first.
///
/// Off by default (the catalog lists it but ``MispherDeepAgent`` adds it only when enabled), since
/// it needs Apple's `container` tool installed.
public struct ContainerShellMiddleware: AgentMiddleware {
    let tool: ContainerShellTool

    /// - Parameters:
    ///   - root: the working folder, mounted into the container at `/workspace`.
    ///   - mode: what to do when the sandbox is unavailable (fail, or fall over to the local shell).
    ///   - image: the OCI image to run, or nil for ``AppleContainerSandbox/defaultImage``.
    public init(root: WorkspaceRoot, mode: SandboxMode = .failover, image: String? = nil) {
        let sandbox = AppleContainerSandbox(root: root, image: image)
        tool = ContainerShellTool(sandbox: sandbox, root: root, mode: mode)
    }

    /// Test seam: inject a sandbox wired to a fake runner.
    init(sandbox: AppleContainerSandbox, root: WorkspaceRoot, mode: SandboxMode) {
        tool = ContainerShellTool(sandbox: sandbox, root: root, mode: mode)
    }

    public var name: String { "container" }
    public var tools: [any AgentTool] { [tool] }

    /// Hard-block catastrophic commands before the approval card, same as the local shell.
    public func wrapToolCall(
        _ request: ToolCallRequest,
        _ handler: (ToolCallRequest) async throws -> AgentMessage
    ) async throws -> AgentMessage {
        if request.call.name == ContainerShellTool.toolName,
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
    ## Sandbox shell with `container_shell`
    Run a command inside an isolated Apple Container sandbox (a Linux container) with your working \
    folder mounted at `/workspace` (its working directory); Python 3.13 and `uv` are preinstalled. \
    Prefer `container_shell` over `shell` for running, building, or testing code, installing \
    packages, and anything you'd rather not run directly on the user's Mac - the container is \
    disposable and the host system stays untouched. Files are shared both ways through the mount, so \
    a file you write with `write_file` is visible here, and files a command creates land back in the \
    working folder. Use the plain `shell` tool only for work that must touch the real macOS system. \
    The user approves every command before it runs, and catastrophic commands are always blocked.
    """
}

/// `container_shell`: run a command via `/bin/sh -c` inside the sandbox container and return its
/// combined output. On an unavailable sandbox it follows the configured ``SandboxMode``.
public struct ContainerShellTool: AgentTool {
    let sandbox: AppleContainerSandbox
    /// The working folder - the mount source, and the cwd for a local fail-over run.
    let root: WorkspaceRoot
    let mode: SandboxMode

    static let toolName = "container_shell"

    public var name: String { Self.toolName }
    public var description: String {
        "Run a shell command inside an isolated container sandbox (Linux, Python + uv) with the "
            + "working folder mounted at /workspace, and return its combined output. Prefer this over "
            + "`shell` for running or building code. Dangerous commands are blocked, and the user "
            + "approves every command before it runs."
    }

    public var parameters: [ToolParameter] {
        [
            .required(
                "command", type: .string,
                description: "The shell command to run, e.g. \"uv run main.py\" or \"python --version\"."
            ),
            .optional(
                "stdin", type: .string,
                description: "Text to feed to the command on standard input."
            ),
            .optional(
                "timeout", type: .int,
                description: "Seconds before the command is killed (default \(ShellTool.defaultTimeout), max \(ShellTool.maxTimeout))."
            )
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let command = ToolArgs.rawString(arguments, "command"),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return ToolOutput("Error: `command` is required.") }

        // Backstop: re-check at execution time, so the block also holds for a command the user edited
        // to something dangerous in the approval card.
        if case .blocked(let reason) = ShellGuard.classify(command) {
            return ToolOutput(ReactAgent.errorJSON(ShellBlock.message(reason)))
        }

        let seconds = min(ShellTool.maxTimeout, max(1, ToolArgs.int(arguments, "timeout") ?? ShellTool.defaultTimeout))
        let stdin = ToolArgs.rawString(arguments, "stdin")
        do {
            try await sandbox.ensureRunning()
            let result = try await sandbox.exec(
                command, stdin: stdin, timeout: TimeInterval(seconds),
                onOutput: { context.onEvent(.toolProgress(name: Self.toolName, subagent: nil, delta: $0)) }
            )
            return ToolOutput(ShellTool.format(result, timeout: seconds))
        } catch let unavailable as SandboxUnavailableError {
            switch mode {
            case .failover:
                return await runLocally(command, stdin: stdin, seconds: seconds, context: context)
            case .containerOnly, .off: // `.off` can't occur (the tool isn't built then); refuse to be safe
                return ToolOutput(ReactAgent.errorJSON(
                    "The container sandbox is unavailable and the container capability is set to "
                        + "\"container only\", so the command was not run. \(unavailable.message)"
                ))
            }
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }

    /// Fail-over path: run the command on the host via `/bin/sh -c`, the same way the local `shell`
    /// tool does, with a note so the model and user know it didn't run in the container.
    private func runLocally(
        _ command: String, stdin: String?, seconds: Int, context: ToolContext
    ) async -> ToolOutput {
        do {
            let result = try await ProcessRunner.run(
                "/bin/sh", ["-c", command], cwd: root.rootURL, stdin: stdin, timeout: TimeInterval(seconds),
                onOutput: { context.onEvent(.toolProgress(name: Self.toolName, subagent: nil, delta: $0)) }
            )
            return ToolOutput("[Sandbox unavailable - ran in the local shell instead.]\n"
                + ShellTool.format(result, timeout: seconds))
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}
