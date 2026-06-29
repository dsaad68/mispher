import Foundation

/// Why a backend `edit` did or didn't apply. Shared by every `FilesystemBackend`. The
/// failure cases carry enough to coach the model toward a fix on its next turn (see
/// ``EditDiagnostics``) rather than just saying "no".
public enum FileEditResult: Sendable {
    /// Applied; `occurrences` is how many copies of `old` were replaced (1 unless `replaceAll`).
    case updated(occurrences: Int)
    /// `old_string` equalled `new_string`, so there was nothing to do (no write happened).
    case noChange
    case fileNotFound
    /// `old` didn't appear exactly; `hint` diagnoses the likely cause (whitespace, indentation,
    /// smart quotes, CRLF, nearest line) so the model can re-copy precisely.
    case notFound(hint: String)
    /// `old` matched more than once (ambiguous) and `replaceAll` was false; the 1-based start
    /// line of every occurrence, so the model can add context or set `replace_all`.
    case notUnique(lines: [Int])
}

/// An operation a backend couldn't perform (unreadable file, path outside the allowed
/// root, …). The filesystem tools catch it and feed the message back to the model as a
/// plain "Error: …" result so it can recover.
public struct FilesystemBackendError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

/// Where `FilesystemMiddleware`'s `ls` / `read_file` / `write_file` / `edit_file` tools
/// store files — Mispher's port of deepagents' `BackendProtocol`. Two implementations:
/// ``StateBackend`` (in-memory scratch space, the default) and ``LocalFilesystemBackend``
/// (the user's real disk). `createDeepAgent` creates one and hands the same instance to
/// the main agent's middleware and to every subagent's, so a file written anywhere in the
/// run is visible everywhere.
public protocol FilesystemBackend: Sendable {
    /// The file paths under `path` (nil = everything / the root), sorted. Backends with a
    /// real directory tree mark directory entries with a trailing "/".
    func list(_ path: String?) async throws -> [String]
    /// The contents of `path`, or `nil` if there is no such file.
    func read(_ path: String) async throws -> String?
    /// Create or overwrite the file at `path`.
    func write(_ path: String, _ content: String) async throws
    /// Replace `old` with `new` in the file at `path`. By default `old` must occur exactly
    /// once so the edit is unambiguous (mirroring the host editor's `Edit`); `replaceAll`
    /// replaces every occurrence instead.
    func edit(_ path: String, replacing old: String, with new: String, replaceAll: Bool) async throws -> FileEditResult
    /// Create the folder at `path` (with any missing parents). Backends without a real
    /// directory tree treat this as a no-op (folders exist implicitly once a file is written).
    func mkdir(_ path: String) async throws

    /// Where these files live, appended to `FilesystemMiddleware`'s system-prompt guidance —
    /// the scratch space and the real disk need opposite "can you open the user's files"
    /// instructions.
    var promptNote: String { get }
    /// Appended to "no file at …" tool errors so the model knows where it CAN look.
    var missingFileHint: String { get }
}

extension FilesystemBackend {
    /// The shared replace algorithm behind `edit`: apply `old` → `new` to `content`
    /// (every occurrence when `replaceAll`, exactly-once otherwise). Matching is always
    /// exact - on a miss it never guesses, but reports *why* and *where* via ``FileEditResult``
    /// so the model can re-copy the text precisely. Returns the updated content when the edit
    /// applied (nil otherwise), plus the outcome to report.
    public static func applyEdit(
        to content: String, replacing old: String, with new: String, replaceAll: Bool
    ) -> (content: String?, result: FileEditResult) {
        if old == new { return (nil, .noChange) }
        guard !old.isEmpty else {
            return (nil, .notFound(hint:
                "old_string is empty - give the exact text to replace, or use write_file to create or overwrite the file."))
        }
        let occurrences = content.components(separatedBy: old).count - 1
        guard occurrences > 0 else {
            return (nil, .notFound(hint: EditDiagnostics.diagnose(content: content, old: old)))
        }
        if !replaceAll && occurrences > 1 {
            return (nil, .notUnique(lines: EditDiagnostics.occurrenceLines(content, old)))
        }
        return (content.replacingOccurrences(of: old, with: new), .updated(occurrences: occurrences))
    }
}

// MARK: - StateBackend (in-memory)

/// A tiny in-memory filesystem — Mispher's port of deepagents' `StateBackend`, and the
/// default. It is an `actor` (so it's `Sendable` and safe to share by reference) and
/// nothing in it ever touches the user's disk. Paths are opaque keys — there is no real
/// directory tree.
actor StateBackend: FilesystemBackend {
    private var files: [String: String]

    init(_ files: [String: String] = [:]) { self.files = files }

    /// Every file path, sorted; with `path`, only the keys under that prefix.
    func list(_ path: String?) -> [String] {
        let all = files.keys.sorted()
        guard let path, !path.isEmpty else { return all }
        return all.filter { $0.hasPrefix(path) }
    }

    func read(_ path: String) -> String? { files[path] }

    func write(_ path: String, _ content: String) { files[path] = content }

    func edit(_ path: String, replacing old: String, with new: String, replaceAll: Bool) -> FileEditResult {
        guard let content = files[path] else { return .fileNotFound }
        let applied = Self.applyEdit(to: content, replacing: old, with: new, replaceAll: replaceAll)
        if let updated = applied.content { files[path] = updated }
        return applied.result
    }

    /// Paths are opaque keys here - there is no real directory tree, so a folder exists
    /// implicitly as soon as a file is written under it. Nothing to create.
    func mkdir(_ path: String) {}

    nonisolated var promptNote: String {
        """
        These files live in a private scratch space, NOT on the user's Mac: you cannot open \
        files or folders from their disk, only what you saved here yourself, and the files \
        last only for this run. If the user asks you to open a file from their computer, say \
        you don't have access to files on their disk.
        """
    }

    nonisolated var missingFileHint: String {
        "These tools cannot open files from the user's disk - only files you saved earlier "
            + "with write_file (see ls)."
    }
}

// MARK: - LocalFilesystemBackend (the user's real disk)

/// The user's real disk — Mispher's port of deepagents' local `FilesystemBackend`.
/// Operations are rooted at `rootURL` (default: the user's home folder): relative paths
/// resolve against it, `~` expands, and absolute paths are accepted as long as they stay
/// inside the root. `..` and symlinks are resolved *before* the containment check
/// (deepagents' `virtual_mode`), so the agent cannot escape the root.
///
/// Reads and writes are real. Pair this backend with ``HumanInTheLoopMiddleware`` so each
/// file the agent touches needs the user's approval first — the same advice deepagents
/// gives for its local backend.
public struct LocalFilesystemBackend: FilesystemBackend {
    let root: WorkspaceRoot
    var rootURL: URL { root.rootURL }

    /// Files bigger than this are refused rather than read into the conversation.
    static let maxReadBytes = 1_000_000

    public init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        root = WorkspaceRoot(rootURL: rootURL)
    }

    /// The root rendered with `~` for prompts and error messages.
    private var displayRoot: String { root.displayRoot }

    public func list(_ path: String?) async throws -> [String] {
        let directory = try resolve(path ?? "")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw FilesystemBackendError("No folder at \"\(path ?? displayRoot)\".")
        }
        guard isDirectory.boolValue else {
            throw FilesystemBackendError("\"\(path ?? "")\" is a file, not a folder - read it with read_file.")
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        // Render entries as paths the model can feed straight back to these tools:
        // prefixed with the queried path as it was given (or bare names at the root).
        let prefix = Self.entryPrefix(path)
        return entries.map { url in
            let name = url.lastPathComponent + (url.hasDirectoryPath ? "/" : "")
            return prefix + name
        }.sorted()
    }

    public func read(_ path: String) async throws -> String? {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue else {
            throw FilesystemBackendError("\"\(path)\" is a folder - list it with ls.")
        }
        // Refuse oversized files by their advertised size *before* allocating them, so a huge
        // file can't blow up memory just to be rejected. The post-read guard stays as a
        // fallback for when the metadata size can't be determined.
        func tooLarge(_ bytes: Int) -> FilesystemBackendError {
            FilesystemBackendError("\"\(path)\" is too large to read (\(bytes) bytes; the limit is \(Self.maxReadBytes)).")
        }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maxReadBytes {
            throw tooLarge(size)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FilesystemBackendError("Couldn't read \"\(path)\": \((error as NSError).localizedDescription)")
        }
        guard data.count <= Self.maxReadBytes else { throw tooLarge(data.count) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw FilesystemBackendError("\"\(path)\" isn't a text file (it can't be decoded as UTF-8).")
        }
        return text
    }

    public func write(_ path: String, _ content: String) async throws {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw FilesystemBackendError("\"\(path)\" is a folder - pass a file path.")
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw FilesystemBackendError("Couldn't write \"\(path)\": \((error as NSError).localizedDescription)")
        }
    }

    public func edit(_ path: String, replacing old: String, with new: String, replaceAll: Bool) async throws -> FileEditResult {
        guard let content = try await read(path) else { return .fileNotFound }
        let applied = Self.applyEdit(to: content, replacing: old, with: new, replaceAll: replaceAll)
        if let updated = applied.content { try await write(path, updated) }
        return applied.result
    }

    public func mkdir(_ path: String) async throws {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return } // already a folder - nothing to do
            throw FilesystemBackendError("\"\(path)\" already exists as a file.")
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw FilesystemBackendError("Couldn't create \"\(path)\": \((error as NSError).localizedDescription)")
        }
    }

    public var promptNote: String {
        """
        These tools work on the user's real Mac filesystem under \(displayRoot) - never claim \
        you can't open the user's files. Paths are relative to that folder (absolute paths \
        and ~ inside it also work): for example `ls` with path "Documents", then `read_file` \
        with "Documents/notes.txt".
        """
    }

    public var missingFileHint: String {
        "Check the path: call ls on its folder to see what is actually there."
    }

    /// Resolve a model-supplied path through the shared ``WorkspaceRoot`` containment check,
    /// re-surfacing a refusal as a ``FilesystemBackendError`` (the type the filesystem tools
    /// already report).
    private func resolve(_ path: String) throws -> URL {
        do {
            return try root.resolve(path)
        } catch let error as WorkspaceRootError {
            throw FilesystemBackendError(error.message)
        }
    }

    /// The prefix `ls` puts before each entry so results are valid tool inputs: the
    /// queried path exactly as the model gave it, with one trailing "/" (empty at the root).
    static func entryPrefix(_ path: String?) -> String {
        guard var prefix = path?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty else {
            return ""
        }
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return prefix.isEmpty ? "/" : prefix + "/"
    }
}
