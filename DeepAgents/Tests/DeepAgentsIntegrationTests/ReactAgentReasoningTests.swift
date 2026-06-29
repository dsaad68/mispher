@testable import DeepAgents
import Testing

/// The agent maps a session's reasoning channel onto `.reasoningToken` events (separate from the
/// answer `.token` channel), in order, so the UI can show a live "thinking…" disclosure. Driven by
/// the scripted `FakeChatModel`, whose `Turn.reasoning` streams on the `.reasoning` channel.
struct ReactAgentReasoningTests {
    private func isReasoning(_ event: AgentEvent) -> Bool {
        if case .reasoningToken = event { return true }
        return false
    }

    private func isToken(_ event: AgentEvent) -> Bool {
        if case .token = event { return true }
        return false
    }

    @Test func reasoningStreamsOnItsOwnChannelBeforeTheAnswer() async {
        let model = FakeChatModel(turns: [
            FakeChatModel.Turn(text: "the answer", toolCalls: [], reasoning: "the thinking")
        ])
        let (ok, events) = await createAgent(model: model).collect([.human("hi")])
        #expect(ok)
        #expect(events.reasoningText == "the thinking")
        #expect(events.tokenText == "the answer")

        // Reasoning is surfaced before the answer it precedes.
        let firstReasoning = events.firstIndex(where: isReasoning)
        let firstToken = events.firstIndex(where: isToken)
        #expect(firstReasoning != nil)
        #expect(firstToken != nil)
        if let firstReasoning, let firstToken { #expect(firstReasoning < firstToken) }
    }

    @Test func reasoningIsStreamedDuringAToolRound() async {
        let model = FakeChatModel(turns: [
            FakeChatModel.Turn(
                text: "", toolCalls: [AgentToolCall(name: "echo", arguments: ["text": .string("x")])],
                reasoning: "planning the call"
            ),
            FakeChatModel.Turn(text: "done", toolCalls: [])
        ])
        let (ok, events) = await createAgent(model: model, tools: [EchoTool()]).collect([.human("hi")])
        #expect(ok)
        #expect(events.reasoningText == "planning the call")
        #expect(events.toolStartedNames.contains("echo"))
        #expect(events.finalAnswer == "done")
    }

    @Test func noReasoningMeansNoReasoningTokens() async {
        let (ok, events) = await createAgent(model: FakeChatModel(answer: "plain")).collect([.human("hi")])
        #expect(ok)
        #expect(events.reasoningText.isEmpty)
        #expect(!events.contains(where: isReasoning))
    }

    @Test func forcedFinalAnswerStreamsReasoning() async {
        // The model keeps re-issuing the identical call until the duplicate-round guard forces a
        // tool-free final turn — where it streams reasoning + the answer (the forceFinalAnswer path).
        let (ok, events) = await createAgent(
            model: ForcingReasoningModel(), tools: [EchoTool()]
        ).collect([.human("go")])
        #expect(ok)
        #expect(events.reasoningText.contains("final thinking"))
        #expect(events.tokenText.contains("the final answer"))
    }
}

/// Loops the identical tool call until the agent forces a tool-free final turn, where it streams
/// reasoning then the answer — exercising the `forceFinalAnswer` path's reasoning channel.
private struct ForcingReasoningModel: ChatModel {
    var supportsVision = false
    func makeSession() -> any ModelTurnSession { ForcingReasoningSession() }
}

private final class ForcingReasoningSession: ModelTurnSession {
    func nextTurn(
        messages _: [AgentMessage], systemPrompt _: String?, tools: [any AgentTool],
        onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
    ) async throws -> AgentMessage {
        guard tools.isEmpty else {
            return .ai("", toolCalls: [AgentToolCall(name: "echo", arguments: ["text": .string("same")])])
        }
        onChunk(.reasoning("final thinking"))
        onChunk(.text("the final answer"))
        return .ai("the final answer", reasoning: "final thinking")
    }
}
