@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// The read-only `git` tools over a throwaway repository, plus a clean message when the
/// folder isn't a repo.
struct GitToolsTests {
    @discardableResult
    private func git(_ arguments: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func withRepo<T>(_ body: (WorkspaceRoot, URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try git(["init", "-q"], in: dir)
        try git(["config", "user.email", "t@e.st"], in: dir)
        try git(["config", "user.name", "Test"], in: dir)
        try "hello\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: dir)
        try git(["commit", "-q", "-m", "initial"], in: dir)
        return try await body(WorkspaceRoot(rootURL: dir), dir)
    }

    @Test func statusOnCleanRepoHasNoError() async throws {
        try await withRepo { root, _ in
            let output = try await GitStatusTool(root: root).execute([:], ToolContext())
            #expect(!output.content.contains("Error"))
        }
    }

    @Test func logShowsTheCommit() async throws {
        try await withRepo { root, _ in
            let output = try await GitLogTool(root: root).execute([:], ToolContext())
            #expect(output.content.contains("initial"))
        }
    }

    @Test func diffShowsUnstagedChange() async throws {
        try await withRepo { root, dir in
            try "hello\nworld\n".write(
                to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
            )
            let output = try await GitDiffTool(root: root).execute([:], ToolContext())
            #expect(output.content.contains("+world"))
        }
    }

    @Test func nonRepositoryReportsCleanly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = try await GitStatusTool(root: WorkspaceRoot(rootURL: dir)).execute([:], ToolContext())
        #expect(output.content.contains("not a git repository"))
    }
}
