@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// The single-shot rebuild engine turns the structured conversation into the chat-template
/// `[Message]` dictionaries every round. `LFM2MessageCodec.renderMessages` is that pure
/// seam: the system prompt must lead exactly once, assistant tool calls must round-trip
/// into the `{"function": {"name", "arguments"}}` shape the LFM2 template reads, and tool
/// results must become plain `tool` turns. These are model-free structural checks.
struct RebuildRenderTests {
    private func render(
        systemPrompt: String? = "You are Mispher.",
        _ messages: [AgentMessage],
        supportsVision: Bool = false
    ) -> [[String: any Sendable]] {
        LFM2MessageCodec.renderMessages(
            systemPrompt: systemPrompt, messages: messages, supportsVision: supportsVision
        ).messages
    }

    @Test func systemPromptLeadsExactlyOnce() {
        let dicts = render([.human("hi"), .ai("hello")])
        #expect(dicts.filter { $0["role"] as? String == "system" }.count == 1)
        #expect(dicts.first?["role"] as? String == "system")
        #expect(dicts.first?["content"] as? String == "You are Mispher.")
        // The conversation follows, in order, mapped to template roles.
        #expect(dicts.map { $0["role"] as? String } == ["system", "user", "assistant"])
    }

    @Test func noSystemPromptOmitsSystemTurn() {
        let dicts = render(systemPrompt: nil, [.human("hi")])
        #expect(dicts.map { $0["role"] as? String } == ["user"])
    }

    @Test func assistantToolCallsRoundTripIntoFunctionShape() {
        let call = AgentToolCall(
            name: "write_clipboard", arguments: ["text": .string("hi"), "count": .int(2)]
        )
        let dicts = render([.human("copy hi"), .ai("", toolCalls: [call])])

        let assistant = dicts.last
        #expect(assistant?["role"] as? String == "assistant")
        let toolCalls = assistant?["tool_calls"] as? [[String: any Sendable]]
        let function = toolCalls?.first?["function"] as? [String: any Sendable]
        #expect(function?["name"] as? String == "write_clipboard")
        // Arguments are rendered as native (Sendable) values the template can format.
        let args = function?["arguments"] as? [String: any Sendable]
        #expect(args?["text"] as? String == "hi")
        #expect(args?["count"] as? Int == 2)
    }

    @Test func toolResultBecomesAToolTurn() {
        let dicts = render([.tool("clipboard: hi", toolCallID: UUID())])
        let tool = dicts.last
        #expect(tool?["role"] as? String == "tool")
        #expect(tool?["content"] as? String == "clipboard: hi")
        // No tool_calls on a result turn.
        #expect(tool?["tool_calls"] == nil)
    }

    @Test func assistantWithoutToolCallsHasNoToolCallsKey() {
        let dicts = render([.ai("just text")])
        let assistant = dicts.last
        #expect(assistant?["content"] as? String == "just text")
        #expect(assistant?["tool_calls"] == nil)
    }

    @Test func visionHumanTurnUsesStructuredImageContent() {
        let url = URL(fileURLWithPath: "/tmp/x.png")
        let (dicts, imageURLs) = LFM2MessageCodec.renderMessages(
            systemPrompt: nil,
            messages: [.human("what is this?", imageURLs: [url])],
            supportsVision: true
        )

        // The image is attached out-of-band and the content is the structured
        // text+image array the VLM template/processor interleave.
        #expect(imageURLs == [url])
        let content = dicts.first?["content"] as? [[String: any Sendable]]
        #expect(content?.map { $0["type"] as? String } == ["text", "image"])
        #expect(content?.first?["text"] as? String == "what is this?")
    }

    @Test func textModelIgnoresImages() {
        let url = URL(fileURLWithPath: "/tmp/x.png")
        let (dicts, imageURLs) = LFM2MessageCodec.renderMessages(
            systemPrompt: nil,
            messages: [.human("what is this?", imageURLs: [url])],
            supportsVision: false
        )
        #expect(imageURLs.isEmpty)
        #expect(dicts.first?["content"] as? String == "what is this?")
    }
}
