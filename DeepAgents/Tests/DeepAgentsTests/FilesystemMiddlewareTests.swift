@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// The filesystem pillar: the in-memory `StateBackend` and its `ls` / `read_file` /
/// `write_file` / `edit_file` tools, plus the fact that a subagent shares the parent's files.
struct FilesystemMiddlewareTests {
    @Test func writeThenReadRoundTrips() async throws {
        let backend = StateBackend()
        _ = try await WriteFileTool(backend: backend).execute(
            ["file_path": .string("notes.txt"), "content": .string("hello")], ToolContext()
        )
        let output = try await ReadFileTool(backend: backend).execute(
            ["file_path": .string("notes.txt")], ToolContext()
        )
        #expect(output.content == "hello")
    }

    @Test func lsListsWrittenFilesSorted() async throws {
        let backend = StateBackend()
        let write = WriteFileTool(backend: backend)
        _ = try await write.execute(["file_path": .string("b.txt"), "content": .string("2")], ToolContext())
        _ = try await write.execute(["file_path": .string("a.txt"), "content": .string("1")], ToolContext())
        let output = try await ListFilesTool(backend: backend).execute([:], ToolContext())
        #expect(output.content == "a.txt\nb.txt")
    }

    @Test func lsWithPathFiltersByPrefix() async throws {
        let backend = StateBackend()
        await backend.write("notes/a.txt", "1")
        await backend.write("other.txt", "2")
        let output = try await ListFilesTool(backend: backend).execute(
            ["path": .string("notes/")], ToolContext()
        )
        #expect(output.content == "notes/a.txt")
    }

    @Test func readMissingFileReturnsError() async throws {
        let output = try await ReadFileTool(backend: StateBackend()).execute(
            ["file_path": .string("nope.txt")], ToolContext()
        )
        #expect(output.content.contains("Error"))
    }

    @Test func editReplacesExactString() async throws {
        let backend = StateBackend()
        await backend.write("f.txt", "the quick brown fox")
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("f.txt"), "old_string": .string("quick"), "new_string": .string("slow")],
            ToolContext()
        )
        #expect(!output.content.contains("Error"))
        let content = await backend.read("f.txt")
        #expect(content == "the slow brown fox")
    }

    @Test func editErrorsWhenOldStringMissing() async throws {
        let backend = StateBackend()
        await backend.write("f.txt", "abc")
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("f.txt"), "old_string": .string("xyz"), "new_string": .string("q")],
            ToolContext()
        )
        #expect(output.content.contains("Error"))
    }

    @Test func editErrorsWhenAmbiguousUnlessReplaceAll() async throws {
        let backend = StateBackend()
        await backend.write("f.txt", "a a a")
        let edit = EditFileTool(backend: backend)
        let ambiguous = try await edit.execute(
            ["file_path": .string("f.txt"), "old_string": .string("a"), "new_string": .string("b")],
            ToolContext()
        )
        #expect(ambiguous.content.contains("Error")) // matches 3 times → refused

        let all = try await edit.execute(
            [
                "file_path": .string("f.txt"), "old_string": .string("a"),
                "new_string": .string("b"), "replace_all": .bool(true)
            ], ToolContext()
        )
        #expect(!all.content.contains("Error"))
        let content = await backend.read("f.txt")
        #expect(content == "b b b")
    }

    @Test func editReportsOccurrenceCountOnReplaceAll() async throws {
        let backend = StateBackend()
        await backend.write("f.txt", "a a a")
        let output = try await EditFileTool(backend: backend).execute(
            [
                "file_path": .string("f.txt"), "old_string": .string("a"),
                "new_string": .string("b"), "replace_all": .bool(true)
            ], ToolContext()
        )
        #expect(output.content.contains("3"))
    }

    @Test func editListsLinesWhenAmbiguous() async throws {
        let backend = StateBackend()
        await backend.write("f.txt", "a\na\na")
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("f.txt"), "old_string": .string("a"), "new_string": .string("b")],
            ToolContext()
        )
        #expect(output.content.contains("Error"))
        #expect(output.content.contains("lines 1, 2, 3"))
    }

    @Test func editReportsNoChangeWhenIdentical() async throws {
        let backend = StateBackend()
        await backend.write("f.txt", "hello world")
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("f.txt"), "old_string": .string("hello"), "new_string": .string("hello")],
            ToolContext()
        )
        #expect(!output.content.contains("Error"))
        #expect(output.content.localizedCaseInsensitiveContains("identical"))
        #expect(await backend.read("f.txt") == "hello world") // untouched
    }

    @Test func editDiagnosesIndentation() async throws {
        let backend = StateBackend()
        await backend.write("f.txt", "if x {\n    foo()\n    bar()\n}")
        let output = try await EditFileTool(backend: backend).execute(
            // old_string indents the block with 2 spaces; the file uses 4, so it never matches exactly.
            ["file_path": .string("f.txt"), "old_string": .string("  foo()\n  bar()"), "new_string": .string("  baz()")],
            ToolContext()
        )
        #expect(output.content.contains("Error"))
        #expect(output.content.localizedCaseInsensitiveContains("indentation"))
        #expect(output.content.contains("line 2"))
    }

    @Test func editDiagnosesTrailingWhitespace() async throws {
        let backend = StateBackend()
        await backend.write("f.txt", "foo")
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("f.txt"), "old_string": .string("foo   "), "new_string": .string("bar")],
            ToolContext()
        )
        #expect(output.content.contains("Error"))
        #expect(output.content.localizedCaseInsensitiveContains("trailing whitespace"))
    }

    @Test func editDiagnosesSmartQuotes() async throws {
        let backend = StateBackend()
        await backend.write("f.txt", "let s = \"hi\"")
        let output = try await EditFileTool(backend: backend).execute(
            // old_string uses curly quotes; the file uses straight quotes.
            ["file_path": .string("f.txt"), "old_string": .string("\u{201C}hi\u{201D}"), "new_string": .string("\"yo\"")],
            ToolContext()
        )
        #expect(output.content.contains("Error"))
        #expect(output.content.localizedCaseInsensitiveContains("smart quotes"))
    }

    @Test func editErrorsWhenFileMissing() async throws {
        let backend = StateBackend()
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("ghost.txt"), "old_string": .string("a"), "new_string": .string("b")],
            ToolContext()
        )
        #expect(output.content.contains("Error"))
        #expect(output.content.localizedCaseInsensitiveContains("no file"))
    }

    @Test func mkdirOnStateBackendSucceeds() async throws {
        let output = try await MakeDirectoryTool(backend: StateBackend()).execute(
            ["path": .string("scratch")], ToolContext()
        )
        #expect(!output.content.contains("Error"))
    }

    /// A subagent shares the deep agent's filesystem: a file it writes is visible on the same
    /// backend the parent holds. Scripts the subagent to call `write_file`, then reads the backend.
    @Test func subagentSharesParentFilesystem() async throws {
        let backend = StateBackend()
        let writeCall = AgentToolCall(
            name: "write_file",
            arguments: [
                "file_path": .string("from_sub.txt"), "content": .string("hello from subagent")
            ]
        )
        let worker = SubAgent(
            name: "worker", description: "writes a file", systemPrompt: "w",
            model: FakeChatModel(answer: "done", toolCalls: [writeCall])
        )
        let middleware = SubAgentMiddleware(
            model: FakeChatModel(), subagents: [worker], backend: backend,
            includeGeneralPurpose: false
        )
        let task = try #require(middleware.tools.first { $0.name == "task" })

        _ = try await task.execute(
            ["description": .string("write the file"), "subagent_type": .string("worker")],
            ToolContext()
        )

        let content = await backend.read("from_sub.txt")
        #expect(content == "hello from subagent")
    }
}

/// The real-disk backend: the same tools over a temporary root directory, plus the path
/// containment that keeps the agent inside its root.
struct LocalFilesystemBackendTests {
    /// A fresh temporary root for one test, removed afterwards.
    private func withRoot<T>(_ body: (LocalFilesystemBackend, URL) async throws -> T) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-fs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(LocalFilesystemBackend(rootURL: root), root)
    }

    @Test func writeThenReadRoundTripsOnDisk() async throws {
        try await withRoot { backend, root in
            _ = try await WriteFileTool(backend: backend).execute(
                ["file_path": .string("notes/draft.txt"), "content": .string("hello disk")], ToolContext()
            )
            let onDisk = try String(
                contentsOf: root.appendingPathComponent("notes/draft.txt"), encoding: .utf8
            )
            #expect(onDisk == "hello disk")

            let output = try await ReadFileTool(backend: backend).execute(
                ["file_path": .string("notes/draft.txt")], ToolContext()
            )
            #expect(output.content == "hello disk")
        }
    }

    @Test func lsListsDirectoryEntriesWithFolderSuffix() async throws {
        try await withRoot { backend, root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("sub"), withIntermediateDirectories: true
            )
            try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

            let top = try await backend.list(nil)
            #expect(top == ["a.txt", "sub/"])
        }
    }

    @Test func lsEntriesAreValidToolInputs() async throws {
        try await withRoot { backend, _ in
            try await backend.write("sub/inner.txt", "1")
            let entries = try await backend.list("sub")
            #expect(entries == ["sub/inner.txt"])
            let first = try #require(entries.first)
            let read = try await backend.read(first)
            #expect(read == "1")
        }
    }

    @Test func editAppliesOnDisk() async throws {
        try await withRoot { backend, _ in
            try await backend.write("f.txt", "the quick brown fox")
            let result = try await backend.edit(
                "f.txt", replacing: "quick", with: "slow", replaceAll: false
            )
            if case .updated = result {} else { Issue.record("expected .updated, got \(result)") }
            let content = try await backend.read("f.txt")
            #expect(content == "the slow brown fox")
        }
    }

    @Test func readMissingFileIsNilAndToolExplains() async throws {
        try await withRoot { backend, _ in
            let direct = try await backend.read("nope.txt")
            #expect(direct == nil)
            let output = try await ReadFileTool(backend: backend).execute(
                ["file_path": .string("nope.txt")], ToolContext()
            )
            #expect(output.content.contains("Error"))
        }
    }

    @Test func pathsOutsideTheRootAreRefused() async throws {
        try await withRoot { backend, _ in
            await #expect(throws: FilesystemBackendError.self) {
                try await backend.read("../escape.txt")
            }
            await #expect(throws: FilesystemBackendError.self) {
                try await backend.write("/etc/mispher-test.txt", "nope")
            }
            // The tool surfaces the refusal as a model-readable error, not a crash.
            let output = try await ReadFileTool(backend: backend).execute(
                ["file_path": .string("../escape.txt")], ToolContext()
            )
            #expect(output.content.contains("Error"))
        }
    }

    @Test func readingAFolderErrorsInsteadOfReturningGarbage() async throws {
        try await withRoot { backend, root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("dir"), withIntermediateDirectories: true
            )
            await #expect(throws: FilesystemBackendError.self) {
                _ = try await backend.read("dir")
            }
        }
    }

    @Test func oversizedFilesAreRefused() async throws {
        try await withRoot { backend, root in
            let big = String(repeating: "x", count: LocalFilesystemBackend.maxReadBytes + 1)
            try big.write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
            await #expect(throws: FilesystemBackendError.self) {
                _ = try await backend.read("big.txt")
            }
        }
    }

    @Test func mkdirCreatesDirectoryOnDisk() async throws {
        try await withRoot { backend, root in
            let output = try await MakeDirectoryTool(backend: backend).execute(
                ["path": .string("a/b/c")], ToolContext()
            )
            #expect(!output.content.contains("Error"))
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: root.appendingPathComponent("a/b/c").path, isDirectory: &isDirectory
            )
            #expect(exists)
            #expect(isDirectory.boolValue)
        }
    }

    @Test func mkdirRefusesOutsideRoot() async throws {
        try await withRoot { backend, _ in
            let output = try await MakeDirectoryTool(backend: backend).execute(
                ["path": .string("../evil")], ToolContext()
            )
            #expect(output.content.contains("Error"))
        }
    }
}
