import Foundation

/// Locates and supervises the local `llama-server` (llama.cpp) processes the app
/// relies on — the Qwen3-ASR server and the LFM2.5 translation server — so the
/// user no longer has to launch them in a terminal. The server is started on
/// demand when the user activates a server-backed model or turns on translation.
///
/// A server that's already answering on its port (started externally, or by us
/// earlier) is reused as-is. Only processes this manager spawned are stopped when
/// the app quits — see `ServerPidRegistry`.
actor LlamaServerManager {
    static let shared = LlamaServerManager()

    /// How to launch one server: where it should answer and the args to pass.
    struct Spec: Sendable {
        let role: String // human label, e.g. "Qwen3-ASR server"
        let baseURL: URL
        let arguments: [String] // everything after the `llama-server` binary
        var port: Int { baseURL.port ?? 0 }
    }

    /// Common `llama-server` install locations (GUI apps inherit a minimal PATH).
    private static let binaryCandidates = [
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
        "/opt/homebrew/opt/llama.cpp/bin/llama-server"
    ]

    private var owned: [Int: Process] = [:] // port -> process we launched
    private var searchedBinary = false
    private var cachedBinary: String?

    /// Ensure `spec`'s server is reachable, launching it if needed and waiting
    /// until it answers. No-op if something already answers on that port.
    func ensureReachable(_ spec: Spec, status: @escaping @Sendable (String) -> Void) async throws {
        if await isReachable(spec.baseURL) { return }

        if owned[spec.port] == nil {
            guard let binary = locateBinary() else { throw AppError.serverBinaryMissing }
            status("Starting \(spec.role)…")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = spec.arguments
            redirectOutput(of: process, port: spec.port)

            do {
                try process.run()
            } catch {
                throw AppError.serverLaunchFailed(spec.role)
            }

            owned[spec.port] = process
            let pid = process.processIdentifier
            ServerPidRegistry.shared.add(pid)
            process.terminationHandler = { _ in ServerPidRegistry.shared.remove(pid) }
        }

        try await waitUntilReachable(spec, status: status)
    }

    // MARK: - Private

    /// Poll until the server answers. First run downloads the GGUF, so allow a
    /// generous window; bail early if the process we own has already exited.
    private func waitUntilReachable(_ spec: Spec, status: @escaping @Sendable (String) -> Void) async throws {
        for attempt in 0 ..< 300 { // ~180s at 600ms
            if await isReachable(spec.baseURL) {
                status("\(spec.role) ready (:\(spec.port))")
                return
            }
            if let process = owned[spec.port], !process.isRunning {
                owned[spec.port] = nil
                throw AppError.serverLaunchFailed(spec.role)
            }
            if attempt == 4 {
                status("Loading \(spec.role)… (first run downloads the model)")
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
        throw AppError.serverLaunchFailed(spec.role)
    }

    private func isReachable(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 1.2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private func locateBinary() -> String? {
        if searchedBinary { return cachedBinary }
        searchedBinary = true
        let fm = FileManager.default
        cachedBinary = Self.binaryCandidates.first { fm.isExecutableFile(atPath: $0) }
            ?? loginShellWhich("llama-server")
        return cachedBinary
    }

    /// GUI apps don't inherit the user's shell PATH, so ask a login shell where
    /// `llama-server` lives as a fallback to the well-known paths.
    private func loginShellWhich(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    private func redirectOutput(of process: Process, port: Int) {
        let logPath = "\(NSTemporaryDirectory())mispher-llama-\(port).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            process.standardOutput = handle
            process.standardError = handle
        }
    }
}

/// Thread-safe registry of child server PIDs we own, so the app can SIGTERM them
/// synchronously on quit (from `applicationWillTerminate`) without awaiting the
/// actor — which might be busy polling for readiness.
final class ServerPidRegistry: @unchecked Sendable {
    static let shared = ServerPidRegistry()

    private let lock = NSLock()
    private var pids: Set<Int32> = []

    func add(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        pids.insert(pid)
    }

    func remove(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        pids.remove(pid)
    }

    func terminateAll() {
        lock.lock()
        let snapshot = pids
        pids.removeAll()
        lock.unlock()
        for pid in snapshot { kill(pid, SIGTERM) }
    }
}
