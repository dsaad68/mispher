import DeepAgents
@testable import Mispher
import Testing

/// Rebuilding a chat transcript from a saved `[AgentMessage]` history (on resume): reasoning is taken
/// from the structured reasoning block when present, falling back to splitting inline `<think>` for
/// legacy messages, and surfaced as a `.reasoning` timeline step on the model's turn.
@MainActor
struct ReconstructTranscriptTests {
    private func reasoningSteps(_ message: MlxModelManager.ChatMessage?) -> [String] {
        (message?.timeline ?? []).compactMap { step in
            if case .reasoning(let value) = step.kind { return value }
            return nil
        }
    }

    @Test func reasoningBlockBecomesAReasoningStep() {
        let chat = MlxModelManager.reconstructTranscript([
            .human("hi"), .ai("the answer", reasoning: "block reasoning")
        ])
        let model = chat.first { $0.role == .model }
        #expect(model?.text == "the answer")
        #expect(reasoningSteps(model) == ["block reasoning"])
    }

    @Test func legacyInlineThinkFallsBackToSplit() {
        let chat = MlxModelManager.reconstructTranscript([.ai("<think>inline</think>answer")])
        let model = chat.first { $0.role == .model }
        #expect(model?.text == "answer")
        #expect(reasoningSteps(model) == ["inline"])
    }

    @Test func cleanAnswerHasNoReasoningStep() {
        let chat = MlxModelManager.reconstructTranscript([.ai("just an answer")])
        let model = chat.first { $0.role == .model }
        #expect(model?.text == "just an answer")
        #expect(reasoningSteps(model).isEmpty)
    }

    @Test func summaryTurnBecomesANoteAndAckIsDropped() {
        // A resumed compacted conversation's stored history is [summary(.human), ack(.ai), real turns].
        // The summary must render as a single dim note, the synthetic ack must be dropped, and neither
        // the summary body nor the ack text may appear as a fake user/model bubble.
        var summary = AgentMessage.human("Earlier messages summarized. Condensed: CONDENSED")
        summary.source = AgentMessage.summarizationSource
        var ack = AgentMessage.ai("Understood. I'll continue from the summary above.")
        ack.source = AgentMessage.summarizationSource
        let chat = MlxModelManager.reconstructTranscript([
            summary, ack, .human("real question"), .ai("real answer")
        ])
        #expect(chat.contains { $0.role == .model && $0.text.contains("summarized") }) // summary -> note
        #expect(!chat.contains { $0.text.contains("CONDENSED") }) // body not shown as a fake user turn
        #expect(!chat.contains { $0.text.contains("Understood. I'll continue") }) // ack dropped
        #expect(chat.first { $0.role == .user }?.text == "real question")
    }

    @Test func toolMessagesCorrelateToTheirStep() {
        let call = AgentToolCall(name: "read_file", arguments: ["path": .string("a.txt")])
        let chat = MlxModelManager.reconstructTranscript([
            .human("read it"),
            .ai("", toolCalls: [call]),
            .tool("file contents", toolCallID: call.id)
        ])
        let model = chat.first { $0.role == .model }
        let toolSteps = (model?.timeline ?? []).compactMap { step -> (name: String, output: String?)? in
            if case .tool(let name, _, let output, _, _, _) = step.kind { return (name, output) }
            return nil
        }
        #expect(toolSteps.count == 1)
        #expect(toolSteps.first?.name == "read_file")
        #expect(toolSteps.first?.output == "file contents") // the tool result lands on its own step
    }
}
