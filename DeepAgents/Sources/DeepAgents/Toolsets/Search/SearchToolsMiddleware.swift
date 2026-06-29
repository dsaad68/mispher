import Foundation

/// Search middleware - `grep` (search file contents), `glob` (find files by path pattern),
/// and `tree` (show the folder layout). All read-only and rooted at the working folder via
/// ``WorkspaceRoot``, so they can't read outside it.
public struct SearchToolsMiddleware: AgentMiddleware {
    let root: WorkspaceRoot

    public init(root: WorkspaceRoot) { self.root = root }

    public var name: String { "search" }
    public var tools: [any AgentTool] {
        [GrepTool(root: root), GlobTool(root: root), TreeTool(root: root)]
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
    ## Search with `grep` / `glob` / `tree`
    Use `grep` to search file *contents* by a regular expression, `glob` to find files whose \
    *path* matches a pattern (e.g. `**/*.swift`), and `tree` to see the folder layout. All \
    three are read-only and stay inside your working folder; pass `path` to scope them to a \
    subfolder.
    """
}

/// `grep`: search file contents under the working folder for a regular expression.
public struct GrepTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "grep" }
    public var description: String {
        "Search file contents under your working folder for a regular expression. "
            + "Returns matching lines as `path:line: text`."
    }

    public var parameters: [ToolParameter] {
        [
            .required("pattern", type: .string, description: "Regular expression to search for."),
            .optional("path", type: .string, description: "File or subfolder to search. Omit for the whole working folder."),
            .optional("include", type: .string, description: "Only search files whose name matches this glob (e.g. *.swift)."),
            .optional("ignore_case", type: .bool, description: "Match case-insensitively.")
        ]
    }

    static let maxResults = 200

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let pattern = ToolArgs.rawString(arguments, "pattern"), !pattern.isEmpty else {
            return ToolOutput("Error: `pattern` is required.")
        }
        var options: NSRegularExpression.Options = []
        if ToolArgs.bool(arguments, "ignore_case") { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return ToolOutput("Error: invalid regular expression: \(pattern)")
        }
        let include = ToolArgs.string(arguments, "include").map(GlobPattern.init)

        let base: URL
        do { base = try root.resolve(ToolArgs.string(arguments, "path") ?? "") } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }

        var results: [String] = []
        var truncated = false
        for file in FileWalk.files(under: base) {
            if let include, !include.matches(file.lastPathComponent) { continue }
            guard let content = FileWalk.readText(file) else { continue }
            let relPath = root.relativePath(file)
            var lineNumber = 0
            content.enumerateLines { line, stop in
                lineNumber += 1
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    results.append("\(relPath):\(lineNumber): \(line.trimmingCharacters(in: .whitespaces))")
                    if results.count >= Self.maxResults { stop = true }
                }
            }
            if results.count >= Self.maxResults { truncated = true; break }
        }
        if results.isEmpty {
            return ToolOutput("No matches for /\(pattern)/ under \"\(root.relativePath(base))\".")
        }
        var output = results.joined(separator: "\n")
        if truncated { output += "\n… (stopped at \(Self.maxResults) matches)" }
        return ToolOutput(output)
    }
}

/// `glob`: find files whose path matches a glob pattern.
public struct GlobTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "glob" }
    public var description: String {
        "Find files under your working folder whose path matches a glob pattern "
            + "(e.g. `**/*.swift`, `src/*.json`). Returns matching paths."
    }

    public var parameters: [ToolParameter] {
        [
            .required(
                "pattern", type: .string,
                description: "Glob: * matches within a path segment, ** across segments, ? one character."
            ),
            .optional("path", type: .string, description: "Subfolder to search from. Omit for the whole working folder.")
        ]
    }

    static let maxResults = 500

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let pattern = ToolArgs.string(arguments, "pattern") else {
            return ToolOutput("Error: `pattern` is required.")
        }
        let base: URL
        do { base = try root.resolve(ToolArgs.string(arguments, "path") ?? "") } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
        let glob = GlobPattern(pattern)
        let matchPath = pattern.contains("/")
        var matches: [String] = []
        for file in FileWalk.files(under: base) {
            let candidate = matchPath ? FileWalk.relativePath(of: file, under: base) : file.lastPathComponent
            if glob.matches(candidate) { matches.append(root.relativePath(file)) }
            if matches.count >= Self.maxResults { break }
        }
        if matches.isEmpty { return ToolOutput("No files match \"\(pattern)\".") }
        return ToolOutput(matches.sorted().joined(separator: "\n"))
    }
}

/// `tree`: render the folder layout under the working folder as an indented tree.
public struct TreeTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "tree" }
    public var description: String {
        "Show the folder layout under your working folder as an indented tree."
    }

    public var parameters: [ToolParameter] {
        [
            .optional("path", type: .string, description: "Subfolder to show. Omit for the whole working folder."),
            .optional("max_depth", type: .int, description: "How many folder levels deep to descend (default 3).")
        ]
    }

    static let maxEntries = 500

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        let base: URL
        do { base = try root.resolve(ToolArgs.string(arguments, "path") ?? "") } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else {
            return ToolOutput("Error: no folder at \"\(root.relativePath(base))\".")
        }
        guard isDirectory.boolValue else { return ToolOutput("\(root.relativePath(base)) (a file, not a folder)") }

        let maxDepth = max(1, ToolArgs.int(arguments, "max_depth") ?? 3)
        let rootLabel = root.relativePath(base)
        var lines = [rootLabel == "." ? "." : rootLabel + "/"]
        var count = 0
        var truncated = false

        func walk(_ directory: URL, prefix: String, depth: Int) {
            if depth > maxDepth || truncated { return }
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }) {
                if count >= Self.maxEntries { truncated = true; return }
                count += 1
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                lines.append("\(prefix)\(entry.lastPathComponent)\(isDir ? "/" : "")")
                if isDir { walk(entry, prefix: prefix + "  ", depth: depth + 1) }
            }
        }
        walk(base, prefix: "  ", depth: 1)
        if truncated { lines.append("… (stopped at \(Self.maxEntries) entries)") }
        return ToolOutput(lines.joined(separator: "\n"))
    }
}

// MARK: - Shared walking & glob matching

/// File-tree walking shared by the search tools, with hard caps so a giant tree can't run
/// unbounded or read oversized/binary files into the conversation.
enum FileWalk {
    static let maxFiles = 5000
    static let maxFileBytes = LocalFilesystemBackend.maxReadBytes

    /// Regular files under `base` (or `base` itself when it's a file), skipping hidden files,
    /// capped at `maxFiles`.
    static func files(under base: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return [base] }
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url)
            }
            if result.count >= maxFiles { break }
        }
        return result
    }

    /// Read `url` as UTF-8 text, skipping files too large or not decodable (likely binary).
    static func readText(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maxFileBytes else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `url` rendered relative to `base`, falling back to the file name.
    static func relativePath(of url: URL, under base: URL) -> String {
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
        if full == basePath { return url.lastPathComponent }
        if full.hasPrefix(basePath + "/") { return String(full.dropFirst(basePath.count + 1)) }
        return url.lastPathComponent
    }
}

/// A glob compiled to an anchored regex. `**` matches across path separators, `*` within a
/// segment, `?` one character; everything else is matched literally.
struct GlobPattern {
    private let regex: NSRegularExpression?

    init(_ glob: String) { regex = try? NSRegularExpression(pattern: Self.translate(glob)) }

    func matches(_ string: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    private static func translate(_ glob: String) -> String {
        var pattern = "^"
        let scalars = Array(glob)
        var index = 0
        while index < scalars.count {
            let character = scalars[index]
            switch character {
            case "*":
                if index + 1 < scalars.count, scalars[index + 1] == "*" {
                    pattern += ".*"
                    index += 2
                    if index < scalars.count, scalars[index] == "/" { index += 1 } // collapse `**/`
                    continue
                }
                pattern += "[^/]*"
            case "?":
                pattern += "[^/]"
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return pattern + "$"
    }
}
