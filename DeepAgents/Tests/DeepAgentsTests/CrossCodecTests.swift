@testable import DeepAgents
@testable import DeepAgentsMLX
@testable import DeepAgentsOpenAI
import Foundation
import Testing

/// Interaction surface: the canonical `AgentMessage` is the interchange between models, so a turn
/// produced by one codec must re-encode cleanly for another (the basis for switching models
/// mid-conversation and cross-model subagents). Reasoning is dropped when replaying history, tool-call
/// ids stay correlated, and images degrade per backend.
struct CrossCodecTests {
    /// Decode a full LFM2 generation (reasoning + answer + a tool call) into one canonical message.
    private func lfm2Decode(_ tokens: [String]) -> AgentMessage {
        let decoder = LFM2Decoder()
        for token in tokens { _ = decoder.ingest(token) }
        return decoder.finish().message
    }

    @Test func lfm2ProducedTurnReEncodesForOpenAIDroppingReasoning() {
        let aiTurn = lfm2Decode([
            "<think>plan</think>", "I'll call ",
            "<|tool_call_start|>[echo(text=\"x\")]<|tool_call_end|>"
        ])
        #expect(aiTurn.reasoning == "plan")
        #expect(aiTurn.toolCalls.first?.name == "echo")
        let callID = aiTurn.toolCalls.first?.id

        let history: [AgentMessage] = [.human("hi"), aiTurn, .tool("echo: x", toolCallID: callID)]
        let rendered = OpenAIMessageCodec.renderMessages(
            systemPrompt: nil, messages: history, supportsVision: false
        )

        let assistant = rendered.first { $0["role"] as? String == "assistant" }
        #expect((assistant?["content"] as? String)?.contains("<think>") == false) // reasoning dropped
        #expect(assistant?["content"] as? String == aiTurn.text)
        let toolCalls = assistant?["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.first?["id"] as? String == callID?.uuidString)
        // The tool result still correlates to the same call id across the codec boundary.
        let toolMsg = rendered.first { $0["role"] as? String == "tool" }
        #expect(toolMsg?["tool_call_id"] as? String == callID?.uuidString)
    }

    @Test func openAIProducedTurnReEncodesForLFM2DroppingReasoning() {
        let aiTurn = AgentMessage.ai(
            "answer", toolCalls: [AgentToolCall(name: "f", arguments: [:])], reasoning: "secret reasoning"
        )
        let dicts = LFM2MessageCodec.renderMessages(
            systemPrompt: nil, messages: [aiTurn], supportsVision: false
        ).messages
        let assistant = dicts.first { $0["role"] as? String == "assistant" }
        #expect(assistant?["content"] as? String == "answer") // reasoning not replayed
        let toolCalls = assistant?["tool_calls"] as? [[String: any Sendable]]
        let function = toolCalls?.first?["function"] as? [String: any Sendable]
        #expect(function?["name"] as? String == "f")
    }

    @Test func base64ImageRendersForOpenAIButLFM2DropsIt() {
        let message = AgentMessage.human("look", images: [AgentImage(base64: "QUJD", mimeType: "image/png")])
        // OpenAI inlines it as a data: URL content part.
        let openai = OpenAIMessageCodec.renderMessages(systemPrompt: nil, messages: [message], supportsVision: true)
        let parts = openai[0]["content"] as? [[String: Any]]
        let url = (parts?.last?["image_url"] as? [String: Any])?["url"] as? String
        #expect(url == "data:image/png;base64,QUJD")
        // LFM2 carries only URL-backed images, so a base64-only image yields no image slot.
        let (dicts, urls) = LFM2MessageCodec.renderMessages(systemPrompt: nil, messages: [message], supportsVision: true)
        #expect(urls.isEmpty)
        #expect(dicts[0]["content"] as? String == "look")
    }
}
