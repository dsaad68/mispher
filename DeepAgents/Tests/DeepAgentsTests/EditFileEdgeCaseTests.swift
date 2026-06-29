@testable import DeepAgents
import Foundation
import Testing

/// Edge cases for `edit_file`, organised by the *property* under test rather than by language.
/// `applyEdit` is pure string work with no language awareness, so a Python vs Rust happy-path
/// would exercise the identical code; instead each test below picks whatever language best
/// *exhibits* a distinct behaviour - literal (non-regex) matching, tab indentation, CRLF,
/// Unicode canonical equivalence, repeated real lines, near-miss diagnosis, byte preservation
/// on disk. Realistic snippets (Python/TS/Shell/Swift/Rust/SQL/Go) are the vehicles.
struct EditFileEdgeCaseTests {
    // MARK: - Matching is literal (not regex / not a replacement template)

    /// A `old_string` full of regex metacharacters must be matched byte-for-byte, never compiled
    /// as a pattern. (Rust/JS regex literal.)
    @Test func oldStringIsMatchedLiterallyNotAsRegex() async throws {
        let backend = StateBackend()
        await backend.write("re.txt", "pattern = r\"^\\d+\\.\\d+(a|b)*$\"")
        let output = try await EditFileTool(backend: backend).execute(
            [
                "file_path": .string("re.txt"),
                "old_string": .string("^\\d+\\.\\d+(a|b)*$"),
                "new_string": .string("^[0-9]+$")
            ], ToolContext()
        )
        #expect(!output.content.contains("Error"))
        #expect(await backend.read("re.txt") == "pattern = r\"^[0-9]+$\"")
    }

    /// `new_string` is inserted verbatim - `$1`, `\2`, `\(x)` are plain characters, not sed
    /// backreferences or Swift interpolation.
    @Test func newStringIsInsertedVerbatim() async throws {
        let backend = StateBackend()
        await backend.write("s.txt", "name = OLD")
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("s.txt"), "old_string": .string("OLD"), "new_string": .string("$1\\2\\(x)")],
            ToolContext()
        )
        #expect(!output.content.contains("Error"))
        #expect(await backend.read("s.txt") == "name = $1\\2\\(x)")
    }

    // MARK: - Whitespace / line-ending near-misses are diagnosed

    /// Go indents with tabs; a space-indented `old_string` never matches exactly, so the error
    /// must point at the line and name indentation as the cause.
    @Test func diagnosesTabVersusSpaceIndentation() async throws {
        let backend = StateBackend()
        await backend.write("main.go", "func main() {\n\tfmt.Println(\"a\")\n\tfmt.Println(\"b\")\n}")
        let output = try await EditFileTool(backend: backend).execute(
            [
                "file_path": .string("main.go"),
                "old_string": .string("    fmt.Println(\"a\")\n    fmt.Println(\"b\")"), // 4 spaces, not a tab
                "new_string": .string("    fmt.Println(\"c\")")
            ], ToolContext()
        )
        #expect(output.content.contains("Error"))
        #expect(output.content.localizedCaseInsensitiveContains("indentation"))
        #expect(output.content.contains("line 2"))
    }

    /// A Windows-authored (CRLF) file whose `old_string` spans a line break with LF must be
    /// diagnosed as a line-ending mismatch rather than a bare "not found".
    @Test func diagnosesCRLFLineEndings() async throws {
        let backend = StateBackend()
        await backend.write("q.sql", "SELECT *\r\nFROM t\r\nWHERE x = 1")
        let output = try await EditFileTool(backend: backend).execute(
            [
                "file_path": .string("q.sql"),
                "old_string": .string("SELECT *\nFROM t"), // LF, file uses CRLF
                "new_string": .string("SELECT a\nFROM t")
            ], ToolContext()
        )
        #expect(output.content.contains("Error"))
        #expect(output.content.localizedCaseInsensitiveContains("CRLF"))
    }

    /// When only the first line of a multi-line `old_string` matches, the error orients the model
    /// to roughly where (the anchor) instead of guessing. (Python, two similar defs.)
    @Test func diagnosesNearestAnchorWhenBlockDiffers() async throws {
        let backend = StateBackend()
        await backend.write("m.py", "def f():\n    return 1\n\ndef g():\n    return 2")
        let output = try await EditFileTool(backend: backend).execute(
            [
                "file_path": .string("m.py"),
                "old_string": .string("def f():\n    return 2"), // first line matches f, body is g's
                "new_string": .string("def f():\n    return 9")
            ], ToolContext()
        )
        #expect(output.content.contains("Error"))
        #expect(output.content.localizedCaseInsensitiveContains("first line"))
        #expect(output.content.contains("line 1"))
    }

    // MARK: - Ambiguity over real, repeated lines

    /// Real code repeats lines (`x = 0`, `}`, `return nil`). Ambiguity must list every line so the
    /// model can disambiguate, and `replace_all` must report how many it changed.
    @Test func listsEveryLineForRepeatedLinesThenReplacesAll() async throws {
        let backend = StateBackend()
        let shell = "a=1\nx=0\nb=2\nx=0\nc=3\nx=0"
        await backend.write("conf.sh", shell)
        let edit = EditFileTool(backend: backend)

        let ambiguous = try await edit.execute(
            ["file_path": .string("conf.sh"), "old_string": .string("x=0"), "new_string": .string("x=9")],
            ToolContext()
        )
        #expect(ambiguous.content.contains("Error"))
        #expect(ambiguous.content.contains("lines 2, 4, 6"))

        let all = try await edit.execute(
            [
                "file_path": .string("conf.sh"), "old_string": .string("x=0"),
                "new_string": .string("x=9"), "replace_all": .bool(true)
            ], ToolContext()
        )
        #expect(all.content.contains("3"))
        #expect(await backend.read("conf.sh") == "a=1\nx=9\nb=2\nx=9\nc=3\nx=9")
    }

    // MARK: - Unicode

    /// Swift's string matching is canonical-equivalence, not byte-equality: a decomposed
    /// `old_string` (e + combining acute) matches composed file text (é = U+00E9), and an emoji on
    /// another line is untouched. So "exact match" here means canonical-exact. (Verified: the
    /// count path and the line-number path agree on this, so there is no count/line skew.)
    @Test func matchesUnicodeCanonicalEquivalence() async throws {
        let backend = StateBackend()
        let composed = "caf\u{00E9}" // café, single-codepoint é
        await backend.write("u.txt", "let s = \"\(composed) ☕\"")
        let output = try await EditFileTool(backend: backend).execute(
            [
                "file_path": .string("u.txt"),
                "old_string": .string("cafe\u{0301}"), // café, decomposed (e + U+0301)
                "new_string": .string("TEA")
            ], ToolContext()
        )
        #expect(!output.content.contains("Error"))
        #expect(await backend.read("u.txt") == "let s = \"TEA ☕\"")
    }

    // MARK: - Boundaries

    /// Editing the final line of a file that has no trailing newline must not add or drop one.
    @Test func editsFinalLineWithoutTrailingNewline() async throws {
        let backend = StateBackend()
        await backend.write("r.rs", "fn a() {}\nfn b() {}\nfn c() {}") // no trailing newline
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("r.rs"), "old_string": .string("fn c() {}"), "new_string": .string("fn d() {}")],
            ToolContext()
        )
        #expect(!output.content.contains("Error"))
        #expect(await backend.read("r.rs") == "fn a() {}\nfn b() {}\nfn d() {}")
    }

    // MARK: - Deletion, empty old_string, and the generic fallback

    /// An empty `new_string` is a deletion: the matched snippet is removed and nothing else shifts.
    @Test func deletesSnippetWhenNewStringEmpty() async throws {
        let backend = StateBackend()
        await backend.write("c.py", "import os\nimport sys\nprint(os.getcwd())")
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("c.py"), "old_string": .string("import sys\n"), "new_string": .string("")],
            ToolContext()
        )
        #expect(!output.content.contains("Error"))
        #expect(await backend.read("c.py") == "import os\nprint(os.getcwd())")
    }

    /// An empty `old_string` addresses nothing, so the tool steers the model to `write_file`
    /// instead of running the near-miss ladder over the whole file.
    @Test func emptyOldStringPointsToWriteFile() async throws {
        let backend = StateBackend()
        await backend.write("e.txt", "anything")
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("e.txt"), "old_string": .string(""), "new_string": .string("X")],
            ToolContext()
        )
        #expect(output.content.contains("Error"))
        #expect(output.content.localizedCaseInsensitiveContains("write_file"))
        #expect(await backend.read("e.txt") == "anything") // untouched
    }

    /// When `old_string` resembles nothing in the file, the ladder must NOT invent a near-miss:
    /// it falls back to a plain "re-read and copy" hint with no spurious line pointer.
    @Test func fallbackHintWhenNoNearMiss() async throws {
        let backend = StateBackend()
        await backend.write("g.txt", "alpha beta gamma")
        let output = try await EditFileTool(backend: backend).execute(
            ["file_path": .string("g.txt"), "old_string": .string("delta epsilon"), "new_string": .string("zeta")],
            ToolContext()
        )
        #expect(output.content.contains("Error"))
        #expect(output.content.localizedCaseInsensitiveContains("read_file"))
        #expect(!output.content.contains("line ")) // no false near-miss anchor
    }

    // MARK: - Real disk: byte preservation through read -> edit -> write

    /// A SQL file with CRLF endings, an emoji, and no trailing newline: a one-line edit must leave
    /// every other byte (the CRLFs, the emoji, the missing final newline) exactly as it was.
    @Test func roundTripPreservesCRLFUnicodeAndNoFinalNewlineOnDisk() async throws {
        try await withRoot { backend, root in
            let original = "SELECT a\r\nFROM t -- ☕\r\nWHERE x = 1"
            let url = root.appendingPathComponent("q.sql")
            try Data(original.utf8).write(to: url)

            let result = try await backend.edit("q.sql", replacing: "WHERE x = 1", with: "WHERE x = 2", replaceAll: false)
            if case .updated = result {} else { Issue.record("expected .updated, got \(result)") }

            let after = try String(contentsOf: url, encoding: .utf8)
            #expect(after == "SELECT a\r\nFROM t -- ☕\r\nWHERE x = 2")
        }
    }

    /// A multi-line block replacement (a TypeScript function body, template literal and all) lands
    /// exactly on disk. (`${name}` exercises literal `$`, `{`, backtick handling.)
    @Test func replacesMultilineBlockOnDisk() async throws {
        try await withRoot { backend, root in
            let original = "function greet(name: string) {\n    console.log(`hi ${name}`)\n    return name\n}"
            let url = root.appendingPathComponent("a.ts")
            try Data(original.utf8).write(to: url)

            let result = try await backend.edit(
                "a.ts",
                replacing: "    console.log(`hi ${name}`)\n    return name",
                with: "    return `hi ${name}`",
                replaceAll: false
            )
            if case .updated = result {} else { Issue.record("expected .updated, got \(result)") }

            let after = try String(contentsOf: url, encoding: .utf8)
            #expect(after == "function greet(name: string) {\n    return `hi ${name}`\n}")
        }
    }

    /// A fresh temporary root for one test, removed afterwards (mirrors `LocalFilesystemBackendTests`).
    private func withRoot<T>(_ body: (LocalFilesystemBackend, URL) async throws -> T) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-edit-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(LocalFilesystemBackend(rootURL: root), root)
    }
}
