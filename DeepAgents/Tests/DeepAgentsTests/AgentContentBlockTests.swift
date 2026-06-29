@testable import DeepAgents
import Foundation
import Testing

/// The content-block message model: accessors, factories, the block Codable, and - critically -
/// backward-compatible decoding of the legacy `{content: String, imageURLs: [...]}` shape so old
/// persisted conversations (e.g. `ConversationStore`) still load.
struct AgentContentBlockTests {
    // MARK: - Accessors & factories

    @Test func accessorsProjectBlocks() {
        let message = AgentMessage.ai("the answer", reasoning: "the thinking")
        #expect(message.text == "the answer")
        #expect(message.reasoning == "the thinking")
        #expect(message.images.isEmpty)
    }

    @Test func humanWithURLImagesExposesImageURLs() {
        let url = URL(fileURLWithPath: "/tmp/a.png")
        let message = AgentMessage.human("look", imageURLs: [url])
        #expect(message.text == "look")
        #expect(message.imageURLs == [url])
    }

    @Test func humanWithBase64ImageKeepsInlineData() {
        let message = AgentMessage.human("look", images: [AgentImage(base64: "QUJD", mimeType: "image/png")])
        #expect(message.images.first?.base64 == "QUJD")
        #expect(message.images.first?.mimeType == "image/png")
        #expect(message.imageURLs.isEmpty) // a base64 image has no URL
    }

    // MARK: - Codable round-trip (new block shape)

    @Test func newShapeRoundTrips() throws {
        let call = AgentToolCall(name: "echo", arguments: ["text": .string("hi")])
        let original = AgentMessage.ai("answer", toolCalls: [call], reasoning: "thinking")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        #expect(decoded.text == "answer")
        #expect(decoded.reasoning == "thinking")
        #expect(decoded.toolCalls.first?.name == "echo")
    }

    @Test func imageBlockRoundTrips() throws {
        let message = AgentMessage.human("look", images: [AgentImage(base64: "QUJD", mimeType: "image/png")])
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        #expect(decoded.images.first?.base64 == "QUJD")
        #expect(decoded.images.first?.mimeType == "image/png")
    }

    // MARK: - Back-compat decode (legacy string content)

    @Test func legacyAIStringRecoversInlineThinkAsReasoning() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","role":"ai",\
        "content":"<think>reasoning here</think>final answer","imageURLs":[]}
        """
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(legacy.utf8))
        #expect(message.reasoning == "reasoning here")
        #expect(message.text == "final answer")
    }

    @Test func legacyHumanStringWithImageURLsBecomesBlocks() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000002","role":"human",\
        "content":"what is this?","imageURLs":["file:///tmp/x.png"]}
        """
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(legacy.utf8))
        #expect(message.text == "what is this?")
        #expect(message.imageURLs == [URL(string: "file:///tmp/x.png")])
    }

    @Test func legacyToolStringRoundTrips() throws {
        let id = UUID()
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000003","role":"tool",\
        "content":"clipboard: hi","toolCallID":"\(id.uuidString)"}
        """
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(legacy.utf8))
        #expect(message.text == "clipboard: hi")
        #expect(message.toolCallID == id)
        #expect(message.reasoning == nil)
    }

    // MARK: - Accessor edge cases

    @Test func emptyContentHasEmptyText() {
        let message = AgentMessage(role: .ai, content: [])
        #expect(message.text.isEmpty)
        #expect(message.reasoning == nil)
        #expect(message.images.isEmpty)
        #expect(message.imageURLs.isEmpty)
    }

    @Test func multipleTextBlocksJoinAndMultipleReasoningJoinWithBlankLine() {
        let message = AgentMessage(role: .ai, content: [.reasoning("a"), .reasoning("b"), .text("x"), .text("y")])
        #expect(message.text == "xy")
        #expect(message.reasoning == "a\n\nb")
    }

    @Test func interleavedBlocksProjectByType() {
        let img = AgentImage(url: URL(fileURLWithPath: "/tmp/a.png"))
        let message = AgentMessage(role: .human, content: [.text("a"), .image(img), .text("b")])
        #expect(message.text == "ab")
        #expect(message.images == [img])
    }

    @Test func allNilImageHasNoURL() {
        let message = AgentMessage.human("x", images: [AgentImage()])
        #expect(message.images.count == 1)
        #expect(message.imageURLs.isEmpty)
    }

    // MARK: - Codable edge cases

    @Test func unknownBlockTypeFailsToDecode() {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","role":"ai",\
        "content":[{"type":"audio","audio":"x"}]}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AgentMessage.self, from: Data(json.utf8))
        }
    }

    @Test func legacyHumanWithoutImageURLsKeyDecodes() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","role":"human","content":"hi"}
        """
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(json.utf8))
        #expect(message.text == "hi")
        #expect(message.images.isEmpty)
    }

    @Test func legacyAIWithMultipleThinkBlocksJoinsReasoning() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000002","role":"ai",\
        "content":"<think>a</think>x<think>b</think>y"}
        """
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(json.utf8))
        #expect(message.reasoning == "a\n\nb")
        #expect(message.text == "xy")
    }

    @Test func legacyAIWithEmptyThinkHasNoReasoning() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000002","role":"ai","content":"<think></think>answer"}
        """
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(json.utf8))
        #expect(message.reasoning == nil)
        #expect(message.text == "answer")
    }

    @Test func newShapeEncodeIsIdempotent() throws {
        let original = AgentMessage.ai(
            "answer",
            toolCalls: [AgentToolCall(name: "f", arguments: ["k": .int(1)])],
            reasoning: "why"
        )
        // Sorted keys so the byte comparison is deterministic (JSONEncoder's default key order isn't).
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data1 = try encoder.encode(original)
        let data2 = try encoder.encode(JSONDecoder().decode(AgentMessage.self, from: data1))
        #expect(data1 == data2)
    }

    @Test func imageURLAndFileIDRoundTrip() throws {
        let message = AgentMessage.human("look", images: [
            AgentImage(url: URL(string: "https://example.com/a.png")),
            AgentImage(fileID: "file-7")
        ])
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.images.count == 2)
        #expect(decoded.images[0].url == URL(string: "https://example.com/a.png"))
        #expect(decoded.images[1].fileID == "file-7")
    }
}
