@testable import DeepAgents
import Foundation
import Testing

/// Interaction surface: conversations persisted before the content-block refactor (the app's
/// `ConversationStore` and the JSONL message log both encode `AgentMessage`) must still load. The
/// back-compat `Codable` reads the legacy `{content: String, imageURLs: [...]}` shape and recovers
/// inline `<think>` as a reasoning block; re-encoding writes the new block shape, stably.
struct PersistenceBackCompatTests {
    private func decode(_ json: String) throws -> AgentMessage {
        try JSONDecoder().decode(AgentMessage.self, from: Data(json.utf8))
    }

    @Test func legacyConversationDecodesToBlocks() throws {
        let legacy = """
        [
          {"id":"00000000-0000-0000-0000-000000000001","role":"human","content":"hi","imageURLs":["file:///tmp/a.png"]},
          {"id":"00000000-0000-0000-0000-000000000002","role":"ai","content":"<think>plan</think>the answer","imageURLs":[]},
          {"id":"00000000-0000-0000-0000-000000000003","role":"tool","content":"result","toolCallID":"00000000-0000-0000-0000-000000000009"}
        ]
        """
        let messages = try JSONDecoder().decode([AgentMessage].self, from: Data(legacy.utf8))
        #expect(messages.count == 3)
        #expect(messages[0].imageURLs == [URL(string: "file:///tmp/a.png")])
        #expect(messages[1].reasoning == "plan")
        #expect(messages[1].text == "the answer")
        #expect(messages[2].text == "result")
        #expect(messages[2].toolCallID == UUID(uuidString: "00000000-0000-0000-0000-000000000009"))
    }

    @Test func reEncodingALegacyMessageIsStable() throws {
        let original = try decode(
            "{\"id\":\"00000000-0000-0000-0000-000000000002\",\"role\":\"ai\"," +
                "\"content\":\"<think>plan</think>answer\",\"imageURLs\":[]}"
        )
        // Sorted keys so the byte comparison is deterministic (JSONEncoder's default key order isn't).
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data1 = try encoder.encode(original)
        let roundTripped = try JSONDecoder().decode(AgentMessage.self, from: data1)
        let data2 = try encoder.encode(roundTripped)
        #expect(data1 == data2) // new-shape encode is idempotent across the round-trip
        #expect(roundTripped.reasoning == "plan")
        #expect(roundTripped.text == "answer")
    }
}
