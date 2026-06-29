import CryptoKit
import Foundation

/// Thrown when the Apple Container sandbox can't be brought up - the `container` tool isn't
/// installed, the service won't start, or the Mac can't run it. ``ContainerShellMiddleware`` maps
/// this to the user's ``SandboxMode``: fail the call, or fail over to the local shell.
struct SandboxUnavailableError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Drives an Apple Container sandbox for the agent: one long-lived Linux container with the working
/// folder bind-mounted at `/workspace`, into which `container_shell` commands are `exec`'d. This is
/// mispher's analogue of a deepagents **sandbox backend** (`SandboxBackendProtocol.execute`) - the
/// swappable, isolated execution environment behind the shell tool.
///
/// Everything shells out to Apple's `container` CLI through ``ProcessRunner`` (the same pattern the
/// `git` / `macos` tools use). The container is created lazily on first use, reused for the rest of
/// the session (so installed packages persist between commands), and torn down on exit via the
/// static ``teardown(for:run:)`` keyed on the deterministic name.
///
/// Requires Apple silicon + macOS 26 and Apple's `container` tool installed; see
/// https://github.com/apple/container.
public actor AppleContainerSandbox {
    /// The default image: Astral's uv image (Alpine + uv + Python 3.13), which has `/bin/sh`.
    public static let defaultImage = "ghcr.io/astral-sh/uv:python3.13-alpine3.23"

    /// Runs one `container` invocation. Receives the bare subcommand argv (e.g. `["run", "-d", …]`);
    /// the default runner prepends the resolved binary. Injectable so tests can assert the argv
    /// without a real `container` (the package is macOS-only, the CLI even more so).
    public typealias Runner = @Sendable (
        _ arguments: [String], _ stdin: String?, _ timeout: TimeInterval,
        _ onOutput: (@Sendable (String) -> Void)?
    ) async throws -> ProcessRunner.Result

    let image: String
    public nonisolated let root: WorkspaceRoot
    /// The container's name - deterministic from the working folder, so a session reuses one
    /// container and teardown can find it without holding this instance.
    public nonisolated let name: String
    private let run: Runner
    /// The in-flight (or completed) bring-up, so concurrent first calls share one create and a
    /// success isn't repeated; a failure clears it so a later call can retry.
    private var bringUpTask: Task<Void, Error>?

    public init(root: WorkspaceRoot, image: String? = nil, run: Runner? = nil) {
        self.root = root
        self.image = image ?? Self.defaultImage
        name = Self.containerName(for: root)
        self.run = run ?? Self.defaultRunner()
    }

    // MARK: - Lifecycle

    /// Bring the container up if it isn't already (idempotent, lazy, shared across turns).
    public func ensureRunning() async throws {
        if let task = bringUpTask { return try await task.value }
        let task = Task { try await self.bringUp() }
        bringUpTask = task
        do {
            try await task.value
        } catch {
            bringUpTask = nil
            throw error
        }
    }

    private func bringUp() async throws {
        try await systemStart()
        try await ensureContainer()
    }

    /// Start the background `container` services (idempotent). Only a hard "not installed" (127 from
    /// the `env` fallback) fails fast here; other non-zero exits - "already running", kernel-install
    /// notices - are left for ``ensureContainer()`` to judge against the real `run`.
    private func systemStart() async throws {
        let result = try await runContainer(["system", "start"], timeout: Self.systemStartTimeout)
        if result.status == 127 { throw SandboxUnavailableError(message: Self.notInstalledMessage) }
    }

    /// Create the long-lived container (auto-pulling the image on first use), or adopt an existing
    /// one of the same name left by a prior session for this same folder.
    private func ensureContainer() async throws {
        let create = try await runContainer(
            ["run", "-d", "--name", name, "--volume", "\(root.rootURL.path):/workspace",
             "--workdir", "/workspace", image, "tail", "-f", "/dev/null"],
            timeout: Self.createTimeout
        )
        if create.succeeded { return }
        // Name already taken -> adopt it (start it if stopped; "already running" means it's ours).
        let adopt = try await runContainer(["start", name], timeout: Self.adoptTimeout)
        if adopt.succeeded || adopt.stderr.lowercased().contains("running") { return }
        if create.status == 127 { throw SandboxUnavailableError(message: Self.notInstalledMessage) }
        let detail = [create.stderr, adopt.stderr].first { !$0.isEmpty } ?? "the container service did not start"
        throw SandboxUnavailableError(message: "couldn't start the sandbox container: \(detail)")
    }

    // MARK: - Execution

    /// Run `command` inside the container at `/workspace`, streaming output via `onOutput`. Assumes
    /// ``ensureRunning()`` has already succeeded. The returned ``ProcessRunner/Result`` carries the
    /// in-container command's exit status and combined output, so ``ShellTool/format(_:timeout:)``
    /// renders it exactly like a local run.
    public func exec(
        _ command: String, stdin: String? = nil, timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessRunner.Result {
        var arguments = ["exec", "--workdir", "/workspace"]
        if stdin != nil { arguments.append("--interactive") }
        arguments += [name, "/bin/sh", "-c", command]
        return try await runContainer(arguments, stdin: stdin, timeout: timeout, onOutput: onOutput)
    }

    /// Stop and remove the session's container (best-effort). Static + keyed on the deterministic
    /// name so the REPL can clean up on exit without holding the instance.
    public static func teardown(for root: WorkspaceRoot, run: Runner? = nil) async {
        let runner = run ?? defaultRunner()
        let name = containerName(for: root)
        _ = try? await runner(["stop", name], nil, teardownTimeout, nil)
        _ = try? await runner(["delete", "--force", name], nil, teardownTimeout, nil)
    }

    // MARK: - Internals

    /// Run one `container` subcommand, mapping a launch failure (the binary is missing) to
    /// ``SandboxUnavailableError`` so callers handle "not installed" uniformly. A non-zero exit is
    /// reported via the returned ``ProcessRunner/Result``, not thrown.
    private func runContainer(
        _ arguments: [String], stdin: String? = nil, timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessRunner.Result {
        do {
            return try await run(arguments, stdin, timeout, onOutput)
        } catch {
            throw SandboxUnavailableError(
                message: "couldn't launch Apple's `container` tool: \(error.localizedDescription)"
            )
        }
    }

    /// A stable container name from the working-folder path, so the same folder reuses one container.
    public static func containerName(for root: WorkspaceRoot) -> String {
        let digest = SHA256.hash(data: Data(root.rootURL.path.utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", Int($0)) }.joined()
        return "mispher-\(hex)"
    }

    /// How to launch the `container` CLI: a concrete path when we can find one (cleaner errors),
    /// else `/usr/bin/env container` so PATH is searched (a GUI-launched app's PATH is thin).
    static func launchConfig() -> (binary: String, prefix: [String]) {
        let candidates = ["/usr/local/bin/container", "/opt/homebrew/bin/container", "/usr/bin/container"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return (path, []) }
        return ("/usr/bin/env", ["container"])
    }

    private static func defaultRunner() -> Runner {
        let (binary, prefix) = launchConfig()
        return { arguments, stdin, timeout, onOutput in
            try await ProcessRunner.run(binary, prefix + arguments, stdin: stdin, timeout: timeout, onOutput: onOutput)
        }
    }

    static let notInstalledMessage = "Apple's `container` tool isn't available. Install it "
        + "(https://github.com/apple/container) and run `container system start`, or set the "
        + "container capability to fail over to the local shell."

    private static let systemStartTimeout: TimeInterval = 90
    /// Generous - the first run pulls the image from the registry.
    private static let createTimeout: TimeInterval = 600
    private static let adoptTimeout: TimeInterval = 30
    private static let teardownTimeout: TimeInterval = 30
}
