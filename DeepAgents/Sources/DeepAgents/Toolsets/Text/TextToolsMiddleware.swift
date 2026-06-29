import Foundation

/// Text middleware - `head`/`tail` (peek at the start/end of a file) and `diff` (compare two
/// files). Read-only and rooted at the working folder via ``WorkspaceRoot``.
public struct TextToolsMiddleware: AgentMiddleware {
    let root: WorkspaceRoot

    public init(root: WorkspaceRoot) { self.root = root }

    public var name: String { "text" }
    public var tools: [any AgentTool] {
        [HeadTool(root: root), TailTool(root: root), DiffTool(root: root)]
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
    ## File text with `head` / `tail` / `diff`
    Use `head` to see the first lines of a file and `tail` for the last lines (handy for logs \
    or large files you don't want to read whole), and `diff` to compare two files. All stay \
    inside your working folder.
    """
}

/// `head`: the first N lines of a text file (default 10).
public struct HeadTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "head" }
    public var description: String { "Show the first lines of a text file (default 10)." }

    public var parameters: [ToolParameter] {
        [
            .required("path", type: .string, description: "File to read."),
            .optional("lines", type: .int, description: "How many lines from the top (default 10).")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        TextTools.peek(root, arguments, fromEnd: false)
    }
}

/// `tail`: the last N lines of a text file (default 10).
public struct TailTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "tail" }
    public var description: String { "Show the last lines of a text file (default 10)." }

    public var parameters: [ToolParameter] {
        [
            .required("path", type: .string, description: "File to read."),
            .optional("lines", type: .int, description: "How many lines from the end (default 10).")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        TextTools.peek(root, arguments, fromEnd: true)
    }
}

/// `diff`: a unified diff of two files, computed by `/usr/bin/diff -u`.
public struct DiffTool: AgentTool {
    let root: WorkspaceRoot
    public var name: String { "diff" }
    public var description: String { "Compare two text files and show a unified diff." }

    public var parameters: [ToolParameter] {
        [
            .required("a", type: .string, description: "First (original) file."),
            .required("b", type: .string, description: "Second (changed) file.")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard let a = ToolArgs.string(arguments, "a"), let b = ToolArgs.string(arguments, "b") else {
            return ToolOutput("Error: both `a` and `b` are required.")
        }
        let urlA: URL, urlB: URL
        do {
            urlA = try root.resolve(a)
            urlB = try root.resolve(b)
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
        do {
            let result = try await ProcessRunner.run("/usr/bin/diff", ["-u", urlA.path, urlB.path], cwd: root.rootURL)
            if result.timedOut { return ToolOutput("Error: diff timed out.") }
            switch result.status {
            case 0: return ToolOutput("The files are identical.")
            case 1: return ToolOutput(result.stdout.isEmpty ? "The files differ." : result.stdout)
            default:
                return ToolOutput("Error: \(result.stderr.isEmpty ? "diff failed (status \(result.status))." : result.stderr)")
            }
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// Shared file reading for `head`/`tail`.
enum TextTools {
    static func peek(_ root: WorkspaceRoot, _ arguments: [String: AgentJSON], fromEnd: Bool) -> ToolOutput {
        guard let path = ToolArgs.string(arguments, "path") else {
            return ToolOutput("Error: `path` is required.")
        }
        let url: URL
        do { url = try root.resolve(path) } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return ToolOutput("Error: no file at \"\(path)\".")
        }
        guard !isDirectory.boolValue else { return ToolOutput("Error: \"\(path)\" is a folder, not a file.") }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= LocalFilesystemBackend.maxReadBytes else {
            return ToolOutput("Error: \"\(path)\" is too large to read.")
        }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return ToolOutput("Error: \"\(path)\" isn't a UTF-8 text file.")
        }
        let count = max(1, ToolArgs.int(arguments, "lines") ?? 10)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let slice = fromEnd ? Array(lines.suffix(count)) : Array(lines.prefix(count))
        let joined = slice.joined(separator: "\n")
        return ToolOutput(joined.isEmpty ? "(file is empty)" : joined)
    }
}
