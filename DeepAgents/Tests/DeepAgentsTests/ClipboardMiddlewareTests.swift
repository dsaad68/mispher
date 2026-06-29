import AppKit
@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import MLXLMCommon
import Testing

/// The clipboard tools: a write→read round-trip and required-argument validation.
/// Serialized because the cases share the one system pasteboard.
@Suite(.serialized)
struct ClipboardMiddlewareTests {
    @Test func writeThenReadRoundTrips() async throws {
        // Preserve and restore the user's clipboard around the test.
        let saved = await MainActor.run { NSPasteboard.general.string(forType: .string) }
        defer {
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                if let saved { NSPasteboard.general.setString(saved, forType: .string) }
            }
        }

        let write = try await WriteClipboardTool()
            .execute(["text": .string("banana split")], ToolContext())
        #expect(write.content.contains("banana split"))

        // The read comes back as the self-describing JSON shape, not bare text.
        let read = try await ReadClipboardTool().execute([:], ToolContext())
        let object = try JSONSerialization.jsonObject(with: Data(read.content.utf8)) as? [String: String]
        #expect(object?["clipboard_text"] == "banana split")
    }

    /// A copied file path must read back verbatim - the JSON must not escape forward slashes
    /// (`\/`), or small models mangle the path when echoing it into a `read_file` call.
    @Test func readClipboardKeepsPathSlashesUnescaped() async throws {
        let saved = await MainActor.run { NSPasteboard.general.string(forType: .string) }
        defer {
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                if let saved { NSPasteboard.general.setString(saved, forType: .string) }
            }
        }

        let path = "/Users/dsaad/GitHub/mispher/STEPS/links.md"
        _ = try await WriteClipboardTool().execute(["text": .string(path)], ToolContext())
        let read = try await ReadClipboardTool().execute([:], ToolContext())
        #expect(read.content.contains(path)) // the path comes back verbatim…
        #expect(!read.content.contains("\\/")) // …with no escaped slashes
    }

    @Test func writeClipboardRequiresText() async throws {
        let output = try await WriteClipboardTool().execute([:], ToolContext())
        #expect(output.content.contains("Error"))
    }
}
