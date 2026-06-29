import Foundation

/// Runs a short-lived helper subprocess off the main thread and returns its captured
/// output. Shared by the command-line tools that shell out (`git`, `diff`, `open`,
/// `open_app`, `mdfind`, `say`, `notify`) - the same `Process` + drain-then-wait pattern
/// ``AppleNotesMiddleware`` and the chat renderer already use, in one place with a timeout.
///
/// Only stdout/stderr are captured; arguments are passed as `argv` (never interpolated into
/// a shell), so there is no shell-injection surface. stdout is drained fully and then stderr:
/// for these commands stderr stays tiny (short error messages), so the two pipes can't both
/// fill and deadlock.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let status: Int32
        /// True when the process was killed for exceeding the timeout.
        public let timedOut: Bool

        public init(stdout: String, stderr: String, status: Int32, timedOut: Bool) {
            self.stdout = stdout
            self.stderr = stderr
            self.status = status
            self.timedOut = timedOut
        }

        /// Whether the process exited cleanly (status 0 and not timed out).
        public var succeeded: Bool { status == 0 && !timedOut }
    }

    struct ProcessRunnerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A background queue for the blocking process work, so waiting on a subprocess never
    /// stalls the agent loop / TUI. Each run is independent, so it need not be serial.
    private static let queue = DispatchQueue(
        label: "com.mispher.tools.process", attributes: .concurrent
    )

    /// Holds the launched `Process` so the timeout watchdog can terminate it from another
    /// thread. `Process` isn't `Sendable`; access is confined to launch (one thread) and a
    /// single `terminate()` from the watchdog, so unchecked is sound here.
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    /// A timeout flag the watchdog sets and the caller reads after the process has exited
    /// (the lock provides the memory ordering across threads).
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Launch `executable` with `arguments` (optionally in `cwd`, optionally feeding
    /// `stdin`), and wait off the main thread until it exits or hits `timeout` seconds.
    /// Throws only when the process can't be launched; a non-zero exit is reported via
    /// `Result.status`.
    /// `onOutput`, when given, is called with each decoded chunk of stdout/stderr as it arrives
    /// (best-effort decoding per chunk; the returned `Result` still carries the authoritative,
    /// fully-decoded capture). It lets a long-running command stream its output live - the shell
    /// tool forwards these as `.toolProgress`. Omit it for the simpler drain-then-wait path the
    /// short helper commands use.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        stdin: String? = nil,
        timeout: TimeInterval = 30,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Swift.Result {
                    try runBlocking(executable, arguments, cwd: cwd, stdin: stdin, timeout: timeout, onOutput: onOutput)
                })
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func runBlocking(
        _ executable: String, _ arguments: [String],
        cwd: URL?, stdin: String?, timeout: TimeInterval,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError(
                message: "couldn't launch \(executable): \(error.localizedDescription)"
            )
        }

        // Kill the process if it overruns the deadline (covers a hung command or a long
        // `say`). Reading stdout below unblocks as soon as the kill closes the pipe.
        let box = ProcessBox(process)
        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            if box.process.isRunning {
                timedOut.set()
                box.process.terminate()
            }
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)

        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()

        let outData: Data, errData: Data
        if let onOutput {
            (outData, errData) = streamPipes(output, errors, onOutput: onOutput)
        } else {
            outData = output.fileHandleForReading.readDataToEndOfFile()
            errData = errors.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        watchdog.cancel()

        return Result(
            stdout: decode(outData),
            stderr: decode(errData),
            status: process.terminationStatus,
            timedOut: timedOut.isSet
        )
    }

    /// Drain both pipes concurrently until EOF, forwarding each decoded chunk to `onOutput` as it
    /// arrives and returning the full captured data. Two readers (stderr on a side thread, stdout
    /// here) so a large stderr - a build's error spew - can't deadlock against stdout.
    private static func streamPipes(
        _ output: Pipe, _ errors: Pipe, onOutput: @escaping @Sendable (String) -> Void
    ) -> (Data, Data) {
        let outAcc = ByteAccumulator(), errAcc = ByteAccumulator()
        let errHandle = HandleBox(errors.fileHandleForReading)
        let errDone = DispatchSemaphore(value: 0)
        queue.async {
            pump(errHandle.handle, into: errAcc, onOutput: onOutput)
            errDone.signal()
        }
        pump(output.fileHandleForReading, into: outAcc, onOutput: onOutput)
        errDone.wait()
        return (outAcc.data, errAcc.data)
    }

    /// Blocking-read `handle` chunk by chunk until EOF (`availableData` returns empty), capturing
    /// the bytes and streaming a best-effort decode of each chunk.
    private static func pump(
        _ handle: FileHandle, into acc: ByteAccumulator, onOutput: @Sendable (String) -> Void
    ) {
        while case let chunk = handle.availableData, !chunk.isEmpty {
            acc.append(chunk)
            if let text = String(data: chunk, encoding: .utf8) ?? String(data: chunk, encoding: .isoLatin1) {
                onOutput(text)
            }
        }
    }

    /// A thread-safe byte sink, capped at ``maxOutputBytes`` so a runaway command can't blow up
    /// memory (it keeps draining the pipe past the cap, just stops storing).
    private final class ByteAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            if bytes.count < maxOutputBytes { bytes.append(data) }
        }

        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    /// Carries a (non-`Sendable`) `FileHandle` into the side-thread pump.
    private final class HandleBox: @unchecked Sendable {
        let handle: FileHandle
        init(_ handle: FileHandle) { self.handle = handle }
    }

    /// Bytes captured from each pipe beyond this are dropped with a marker, so a runaway
    /// command can't blow up memory or the conversation.
    static let maxOutputBytes = 200_000

    private static func decode(_ data: Data) -> String {
        let clipped = data.count > maxOutputBytes ? data.prefix(maxOutputBytes) : data
        // UTF-8 for normal output; Latin-1 never fails, so odd bytes still decode rather than
        // dropping the whole result.
        var text = String(bytes: clipped, encoding: .utf8)
            ?? String(bytes: clipped, encoding: .isoLatin1) ?? ""
        if data.count > maxOutputBytes { text += "\n… (output truncated)" }
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
