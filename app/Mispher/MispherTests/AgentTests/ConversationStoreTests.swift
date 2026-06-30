import DeepAgents
import Foundation
@testable import Mispher
import Testing

/// `ConversationStore` persists an Ask conversation's `[AgentMessage]` history as JSONL. With the
/// content-block message model, a saved conversation must round-trip its reasoning and image blocks.
/// (Legacy string-content decoding is covered at the framework level in `PersistenceBackCompatTests`.)
struct ConversationStoreTests {
    private func tempStore() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("convstore-\(UUID().uuidString)", isDirectory: true)
        return (ConversationStore(directory: dir), dir)
    }

    @Test func roundTripsReasoningAndImageBlocks() async {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let messages: [AgentMessage] = [
            .human("look", images: [AgentImage(base64: "QUJD", mimeType: "image/png")]),
            .ai("the answer", reasoning: "the thinking")
        ]
        await store.save("thread-1", messages)
        let loaded = await store.load("thread-1")

        #expect(loaded.count == 2)
        #expect(loaded[0].text == "look")
        #expect(loaded[0].images.first?.base64 == "QUJD")
        #expect(loaded[1].text == "the answer")
        #expect(loaded[1].reasoning == "the thinking")
    }

    @Test func loadingAnUnknownThreadIsEmpty() async {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = await store.load("nope")
        #expect(loaded.isEmpty)
    }

    @Test func titleIgnoresSummaryTurns() async {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // After a compaction the first turn is a synthetic summary (a `.human`). The title must skip it
        // and use the first real user turn, not the summary boilerplate.
        var summary = AgentMessage.human("You are continuing a conversation whose earlier messages ...")
        summary.source = AgentMessage.summarizationSource
        await store.save("t", [summary, .ai("ack"), .human("the original question")])
        #expect(await store.meta("t")?.title == "the original question")
    }

    @Test func loadsLegacyStringContentFileFromDisk() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Line 0 is the metadata header (dropped on read); line 1 is a pre-refactor message
        // (`content` as a String, with inline `<think>`) — the store must still load it.
        let legacy = """
        {"id":"legacy","model":"m","title":"t","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        {"id":"00000000-0000-0000-0000-000000000002","role":"ai","content":"<think>plan</think>answer","imageURLs":[]}
        """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("legacy.jsonl"))

        let loaded = await store.load("legacy")
        #expect(loaded.count == 1)
        #expect(loaded[0].reasoning == "plan")
        #expect(loaded[0].text == "answer")
    }
}
