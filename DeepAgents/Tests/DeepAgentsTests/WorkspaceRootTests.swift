@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import Testing

/// The shared sandbox boundary: paths resolve under the root, and `..`, absolute paths, and
/// symlinks can't escape it. This is the security-critical containment every command-line
/// tool relies on.
struct WorkspaceRootTests {
    private func withRoot<T>(_ body: (WorkspaceRoot, URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(WorkspaceRoot(rootURL: dir), dir)
    }

    /// Assert that resolving `path` is refused as a containment violation.
    private func expectRefused(_ root: WorkspaceRoot, _ path: String) {
        do {
            _ = try root.resolve(path)
            Issue.record("expected \"\(path)\" to be refused")
        } catch {
            #expect(error is WorkspaceRootError)
        }
    }

    @Test func relativePathResolvesUnderRoot() throws {
        try withRoot { root, _ in
            let resolved = try root.resolve("notes/a.txt")
            #expect(resolved.path.hasPrefix(root.rootURL.path))
            #expect(resolved.path.hasSuffix("notes/a.txt"))
        }
    }

    @Test func emptyPathResolvesToRoot() throws {
        try withRoot { root, _ in
            let resolved = try root.resolve("")
            #expect(resolved == root.rootURL)
        }
    }

    @Test func dotDotEscapeIsRefused() throws {
        try withRoot { root, _ in expectRefused(root, "../escape.txt") }
    }

    @Test func absolutePathOutsideRootIsRefused() throws {
        try withRoot { root, _ in expectRefused(root, "/etc/hosts") }
    }

    @Test func symlinkEscapeIsRefused() throws {
        try withRoot { root, dir in
            // A symlink inside the root that points outside it is not an escape hatch: the link
            // is resolved before the containment check.
            try FileManager.default.createSymbolicLink(
                at: dir.appendingPathComponent("out"), withDestinationURL: URL(fileURLWithPath: "/etc")
            )
            expectRefused(root, "out/hosts")
        }
    }

    @Test func relativePathRendersUnderRoot() throws {
        try withRoot { root, dir in
            #expect(root.relativePath(dir.appendingPathComponent("sub/file.txt")) == "sub/file.txt")
            #expect(root.relativePath(dir) == ".")
        }
    }
}
