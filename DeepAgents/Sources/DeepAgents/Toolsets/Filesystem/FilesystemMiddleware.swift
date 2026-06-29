import Foundation

/// Filesystem middleware — Mispher's port of deepagents' `FilesystemMiddleware`. It
/// contributes `ls`, `read_file`, `write_file`, and `edit_file` tools over a
/// ``FilesystemBackend`` and appends usage guidance so the model knows the tools exist.
///
/// The backend decides what the tools actually touch: the default ``StateBackend`` is a
/// private in-memory scratch space for notes, drafts, and intermediate results, while
/// ``LocalFilesystemBackend`` operates on the user's real disk (pair that one with
/// ``HumanInTheLoopMiddleware`` so every read and write needs the user's approval).
public struct FilesystemMiddleware: AgentMiddleware {
    let backend: any FilesystemBackend

    init(backend: any FilesystemBackend = StateBackend()) { self.backend = backend }

    public var name: String { "filesystem" }
    public var tools: [any AgentTool] {
        [
            ListFilesTool(backend: backend),
            ReadFileTool(backend: backend),
            WriteFileTool(backend: backend),
            EditFileTool(backend: backend),
            MakeDirectoryTool(backend: backend)
        ]
    }

    /// Append filesystem usage guidance to the system prompt for every model call (the
    /// `TodoListMiddleware` / `ScreenshotMiddleware` pattern). The mechanics are shared;
    /// the backend supplies the where-do-these-files-live note.
    public func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        let composed = [request.systemPrompt, Self.systemPrompt(for: backend)]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return try await handler(request.override(systemPrompt: composed))
    }

    static func systemPrompt(for backend: any FilesystemBackend) -> String {
        """
        ## Working files with `ls` / `read_file` / `write_file` / `edit_file` / `mkdir`
        Use `write_file` to save notes, drafts, or results, `read_file` to read a file \
        back, `ls` to see what exists (pass `path` to look inside one folder), `edit_file` \
        to change part of a file (it replaces an exact snippet - copy the text to replace \
        verbatim from `read_file`; if it doesn't match, the error tells you why and where), \
        and `mkdir` to create a folder (`write_file` already makes missing parent folders, \
        so you rarely need it). \
        Prefer the filesystem over keeping large content in the conversation. Files are \
        shared with any subagents you delegate to.
        \(backend.promptNote)
        """
    }
}

/// `ls`: list the files in the agent's filesystem (optionally one folder of it).
public struct ListFilesTool: AgentTool {
    let backend: any FilesystemBackend
    public var name: String { "ls" }
    public var description: String {
        "List the file paths in your working filesystem. Pass `path` to list just one folder."
    }

    public var parameters: [ToolParameter] {
        [.optional("path", type: .string, description: "Folder to list. Omit for the top level.")]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        var path: String?
        if case .string(let raw)? = arguments["path"], !raw.isEmpty { path = raw }
        do {
            let files = try await backend.list(path)
            if files.isEmpty {
                let location = path.map { "at \"\($0)\"" } ?? "yet"
                return ToolOutput("No files \(location). \(backend.missingFileHint)")
            }
            return ToolOutput(files.joined(separator: "\n"))
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// `read_file`: return the full contents of a file.
public struct ReadFileTool: AgentTool {
    let backend: any FilesystemBackend
    public var name: String { "read_file" }
    public var description: String { "Read the full contents of a file in your working filesystem." }

    public var parameters: [ToolParameter] {
        [.required("file_path", type: .string, description: "Path of the file to read.")]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard case .string(let path)? = arguments["file_path"] else {
            return ToolOutput("Error: `file_path` is required.")
        }
        do {
            guard let content = try await backend.read(path) else {
                return ToolOutput("Error: no file at \"\(path)\". \(backend.missingFileHint)")
            }
            return ToolOutput(content.isEmpty ? "(file is empty)" : content)
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// `write_file`: create or overwrite a file.
public struct WriteFileTool: AgentTool {
    let backend: any FilesystemBackend
    public var name: String { "write_file" }
    public var description: String { "Create or overwrite a file in your working filesystem." }

    public var parameters: [ToolParameter] {
        [
            .required("file_path", type: .string, description: "Path of the file to write."),
            .required("content", type: .string, description: "The full contents to write.")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard case .string(let path)? = arguments["file_path"] else {
            return ToolOutput("Error: `file_path` is required.")
        }
        let content: String
        if case .string(let text)? = arguments["content"] { content = text } else { content = "" }
        do {
            try await backend.write(path, content)
            return ToolOutput("Wrote \(content.count) character(s) to \"\(path)\".")
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// `mkdir`: create a folder (with any missing parents) in the agent's filesystem.
public struct MakeDirectoryTool: AgentTool {
    let backend: any FilesystemBackend
    public var name: String { "mkdir" }
    public var description: String {
        "Create a new folder (and any missing parent folders) in your working filesystem."
    }

    public var parameters: [ToolParameter] {
        [.required("path", type: .string, description: "Path of the folder to create.")]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard case .string(let path)? = arguments["path"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ToolOutput("Error: `path` is required.")
        }
        do {
            try await backend.mkdir(path)
            return ToolOutput("Created folder \"\(path)\".")
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// `edit_file`: replace an exact snippet within a file.
public struct EditFileTool: AgentTool {
    let backend: any FilesystemBackend
    public var name: String { "edit_file" }
    public var description: String {
        "Replace an exact string in a file. old_string must match the file character-for-character "
            + "(including whitespace and indentation) and, by default, appear exactly once - set "
            + "replace_all to true to replace every occurrence. On a miss the error explains why and "
            + "where so you can re-copy precisely."
    }

    public var parameters: [ToolParameter] {
        [
            .required("file_path", type: .string, description: "Path of the file to edit."),
            .required("old_string", type: .string, description: "The exact text to replace."),
            .required("new_string", type: .string, description: "The replacement text."),
            .optional(
                "replace_all", type: .bool,
                description: "Replace every occurrence instead of requiring a unique match."
            )
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard case .string(let path)? = arguments["file_path"] else {
            return ToolOutput("Error: `file_path` is required.")
        }
        guard case .string(let old)? = arguments["old_string"] else {
            return ToolOutput("Error: `old_string` is required.")
        }
        let new: String
        if case .string(let text)? = arguments["new_string"] { new = text } else { new = "" }
        var replaceAll = false
        if case .bool(let flag)? = arguments["replace_all"] { replaceAll = flag }

        do {
            // Snapshot the file before editing so we can diff against the post-edit contents.
            let before = try? await backend.read(path)
            switch try await backend.edit(path, replacing: old, with: new, replaceAll: replaceAll) {
            case .updated(let count):
                let text = count > 1 ? "Edited \"\(path)\" (replaced \(count) occurrences)." : "Edited \"\(path)\"."
                // Compute a UI-only diff (the model still sees only `text`); attach it the way the
                // screenshot tool attaches images - via the state update, read back in dispatchTool.
                let after = try? await backend.read(path)
                let diff = before.flatMap { old in
                    after.flatMap { new in FileDiff.compute(path: path, before: old, after: new) }
                }
                return ToolOutput(text, stateUpdate: diff.map { .set(EditDiffState.pendingKey, $0) })
            case .noChange:
                return ToolOutput("Nothing to change: old_string and new_string are identical.")
            case .fileNotFound:
                return ToolOutput("Error: no file at \"\(path)\". \(backend.missingFileHint)")
            case .notFound(let hint):
                return ToolOutput("Error: couldn't find that exact text in \"\(path)\". \(hint)")
            case .notUnique(let lines):
                let list = lines.map(String.init).joined(separator: ", ")
                return ToolOutput(
                    "Error: that text appears \(lines.count) times in \"\(path)\" (lines \(list)); add "
                        + "surrounding context to make it unique, or set replace_all to change all of them."
                )
            }
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}
