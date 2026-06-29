import Foundation

/// The directory a tool is allowed to touch, and the single place the "stay inside the
/// working folder" rule lives. ``LocalFilesystemBackend`` and the command-line tools
/// (`grep`/`glob`/`tree`/`head`/`tail`/`diff`/`git`/`open`/`download`/…) all resolve
/// model-supplied paths through here, so the sandbox boundary has one implementation.
///
/// A path resolves against `rootURL`: `~` expands, relative paths join the root, and
/// absolute paths are accepted only while they stay inside it. `..` is collapsed and
/// symlinks are resolved *before* the containment check (deepagents' `virtual_mode`), so
/// neither can escape the root.
public struct WorkspaceRoot: Sendable {
    public let rootURL: URL

    public init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The root rendered with `~`, for prompts and error messages.
    public var displayRoot: String { (rootURL.path as NSString).abbreviatingWithTildeInPath }

    /// Resolve a model-supplied path against the root and refuse anything that lands
    /// outside it. An empty path resolves to the root itself.
    public func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = NSString(string: trimmed).expandingTildeInPath
        guard !expanded.isEmpty else { return rootURL }
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: expanded, relativeTo: rootURL)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == rootURL.path || resolved.path.hasPrefix(rootURL.path + "/") else {
            throw WorkspaceRootError(
                "\"\(path)\" is outside the allowed folder (\(displayRoot)). Use a path under it."
            )
        }
        return resolved
    }

    /// `url` rendered relative to the root - the compact, model-friendly form the search
    /// and tree tools echo back. Falls back to the absolute path if `url` is somehow outside.
    public func relativePath(_ url: URL) -> String {
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        if full == rootURL.path { return "." }
        if full.hasPrefix(rootURL.path + "/") { return String(full.dropFirst(rootURL.path.count + 1)) }
        return full
    }
}

/// A path that fell outside the workspace root. Tools catch it and feed the message back to
/// the model as a plain "Error: …" result so it can correct course (the same contract
/// ``FilesystemBackendError`` follows).
public struct WorkspaceRootError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
