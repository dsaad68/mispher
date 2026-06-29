@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// The `search` tools (`grep` / `glob` / `tree`) over a temporary tree, plus the fact that an
/// out-of-root `path` is refused.
struct SearchToolsTests {
    private func withTree<T>(_ body: (WorkspaceRoot, URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("src"), withIntermediateDirectories: true
        )
        try "import Foundation\nlet answer = 42\n"
            .write(to: dir.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        try "the answer is 42\n"
            .write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(WorkspaceRoot(rootURL: dir), dir)
    }

    @Test func grepFindsMatchesWithLineNumbers() async throws {
        try await withTree { root, _ in
            let output = try await GrepTool(root: root).execute(["pattern": .string("answer")], ToolContext())
            #expect(output.content.contains("src/a.swift:2:"))
            #expect(output.content.contains("notes.txt:1:"))
        }
    }

    @Test func grepIncludeFiltersByGlob() async throws {
        try await withTree { root, _ in
            let output = try await GrepTool(root: root).execute(
                ["pattern": .string("answer"), "include": .string("*.swift")], ToolContext()
            )
            #expect(output.content.contains("a.swift"))
            #expect(!output.content.contains("notes.txt"))
        }
    }

    @Test func grepRefusesOutOfRootPath() async throws {
        try await withTree { root, _ in
            let output = try await GrepTool(root: root).execute(
                ["pattern": .string("x"), "path": .string("../")], ToolContext()
            )
            #expect(output.content.contains("Error"))
        }
    }

    @Test func globMatchesAcrossSegments() async throws {
        try await withTree { root, _ in
            let output = try await GlobTool(root: root).execute(["pattern": .string("**/*.swift")], ToolContext())
            #expect(output.content.contains("src/a.swift"))
            #expect(!output.content.contains("notes.txt"))
        }
    }

    @Test func treeShowsLayout() async throws {
        try await withTree { root, _ in
            let output = try await TreeTool(root: root).execute([:], ToolContext())
            #expect(output.content.contains("src/"))
            #expect(output.content.contains("a.swift"))
            #expect(output.content.contains("notes.txt"))
        }
    }
}
