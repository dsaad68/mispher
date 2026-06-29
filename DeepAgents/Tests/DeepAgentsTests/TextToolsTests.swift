@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// The `text` tools (`head` / `tail` / `diff`) over temporary files, plus containment.
struct TextToolsTests {
    private func withFiles<T>(_ body: (WorkspaceRoot, URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body20 = (1 ... 20).map { "line \($0)" }.joined(separator: "\n")
        try body20.write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(WorkspaceRoot(rootURL: dir), dir)
    }

    @Test func headReturnsFirstLines() async throws {
        try await withFiles { root, _ in
            let output = try await HeadTool(root: root).execute(
                ["path": .string("f.txt"), "lines": .int(3)], ToolContext()
            )
            #expect(output.content == "line 1\nline 2\nline 3")
        }
    }

    @Test func tailReturnsLastLines() async throws {
        try await withFiles { root, _ in
            let output = try await TailTool(root: root).execute(
                ["path": .string("f.txt"), "lines": .int(2)], ToolContext()
            )
            #expect(output.content == "line 19\nline 20")
        }
    }

    @Test func diffShowsChanges() async throws {
        try await withFiles { root, dir in
            try "a\nb\nc\n".write(to: dir.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
            try "a\nB\nc\n".write(to: dir.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
            let output = try await DiffTool(root: root).execute(
                ["a": .string("x.txt"), "b": .string("y.txt")], ToolContext()
            )
            #expect(output.content.contains("-b"))
            #expect(output.content.contains("+B"))
        }
    }

    @Test func diffReportsIdenticalFiles() async throws {
        try await withFiles { root, dir in
            try "same\n".write(to: dir.appendingPathComponent("p.txt"), atomically: true, encoding: .utf8)
            try "same\n".write(to: dir.appendingPathComponent("q.txt"), atomically: true, encoding: .utf8)
            let output = try await DiffTool(root: root).execute(
                ["a": .string("p.txt"), "b": .string("q.txt")], ToolContext()
            )
            #expect(output.content.contains("identical"))
        }
    }

    @Test func headRefusesOutOfRoot() async throws {
        try await withFiles { root, _ in
            let output = try await HeadTool(root: root).execute(["path": .string("../secret.txt")], ToolContext())
            #expect(output.content.contains("Error"))
        }
    }
}
