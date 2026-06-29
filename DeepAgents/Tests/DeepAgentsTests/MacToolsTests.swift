@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// The `macos` tools that are safe to exercise without side effects: `download` (against a
/// stub client) and the argument-validation paths of the others. `open`/`open_app`/`say`/
/// `notify`/`mdfind` are not run for real here - they launch apps, speak, or post UI.
struct MacToolsTests {
    private struct StubClient: HTTPClient {
        let response: HTTPResponse
        func send(_ request: HTTPRequest) async throws -> HTTPResponse { response }
    }

    private func okClient(_ body: String) throws -> StubClient {
        let url = try #require(URL(string: "https://example.com/file.txt"))
        return StubClient(response: HTTPResponse(
            statusCode: 200, headers: [:], body: Data(body.utf8), finalURL: url, mimeType: "text/plain"
        ))
    }

    private func withRoot<T>(_ body: (WorkspaceRoot, URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(WorkspaceRoot(rootURL: dir), dir)
    }

    @Test func downloadWritesFileInRoot() async throws {
        try await withRoot { root, dir in
            let tool = try DownloadTool(root: root, client: okClient("payload"))
            let output = try await tool.execute(
                ["url": .string("https://example.com/file.txt"), "path": .string("out/data.txt")], ToolContext()
            )
            #expect(!output.content.contains("Error"))
            let written = try String(contentsOf: dir.appendingPathComponent("out/data.txt"), encoding: .utf8)
            #expect(written == "payload")
        }
    }

    @Test func downloadRefusesOutOfRootDestination() async throws {
        try await withRoot { root, _ in
            let tool = try DownloadTool(root: root, client: okClient("x"))
            let output = try await tool.execute(
                ["url": .string("https://example.com/file.txt"), "path": .string("../escape.txt")], ToolContext()
            )
            #expect(output.content.contains("Error"))
        }
    }

    @Test func downloadRejectsNonHTTPURL() async throws {
        try await withRoot { root, _ in
            let tool = try DownloadTool(root: root, client: okClient("x"))
            let output = try await tool.execute(
                ["url": .string("ftp://example.com/x"), "path": .string("a.txt")], ToolContext()
            )
            #expect(output.content.contains("Error"))
        }
    }

    @Test func spotlightRejectsOptionLikeQuery() async throws {
        try await withRoot { root, _ in
            let output = try await SpotlightTool(root: root).execute(["query": .string("-foo")], ToolContext())
            #expect(output.content.contains("Error"))
        }
    }

    @Test func openRequiresTarget() async throws {
        try await withRoot { root, _ in
            let output = try await OpenTool(root: root).execute([:], ToolContext())
            #expect(output.content.contains("Error"))
        }
    }
}
