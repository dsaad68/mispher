@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import MLXLMCommon
import Testing

/// The subagent / delegation pillar — Mispher's mirror of deepagents' `test_subagent_middleware.py`
/// / `test_subagents.py`: the `task` tool routes to named subagents, returns their final result to
/// the parent, isolates their context, and reports an unknown `subagent_type` gracefully.
struct SubAgentMiddlewareTests {
    private func taskCall(_ description: String, _ type: String) -> AgentToolCall {
        AgentToolCall(
            name: "task",
            arguments: ["description": .string(description), "subagent_type": .string(type)]
        )
    }

    @Test func taskToolDescriptionListsSubagentsIncludingGeneralPurpose() throws {
        let writer = SubAgent(name: "writer", description: "drafts prose", systemPrompt: "w")
        let middleware = SubAgentMiddleware(model: FakeChatModel(), subagents: [writer])
        let task = try #require(middleware.tools.first { $0.name == "task" })
        #expect(task.description.contains("general-purpose"))
        #expect(task.description.contains("writer"))
    }

    @Test func taskToolRunsNamedSubagentAndReturnsItsFinalAnswer() async {
        // The subagent gets its own scripted model so its result is deterministic.
        let writer = SubAgent(
            name: "writer", description: "drafts prose", systemPrompt: "You write.",
            model: FakeChatModel(answer: "SUBAGENT REPLY")
        )
        let agent = createDeepAgent(
            model: FakeChatModel(answer: "done", toolCalls: [taskCall("write a haiku", "writer")]),
            subagents: [writer]
        )
        let (ok, events) = await agent.collect([.human("delegate please")])
        #expect(ok)
        // The subagent's final message is handed back as the `task` tool result.
        let result = events.toolCompletedResults.first { $0.name == "task" }?.result
        #expect(result == "SUBAGENT REPLY")
    }

    @Test func taskToolReturnsErrorForUnknownSubagentType() async {
        let agent = createDeepAgent(
            model: FakeChatModel(answer: "ok", toolCalls: [taskCall("do it", "nope")])
        )
        let (ok, events) = await agent.collect([.human("go")])
        #expect(ok) // unknown type is a graceful tool error, not a crash
        // The dispatcher's schema validation rejects the bad `subagent_type` before the
        // tool runs, feeding a correction back to the model.
        let error = events.toolFailures.first { $0.name == "task" }?.error ?? ""
        #expect(error.contains("nope"))
        #expect(error.contains("general-purpose")) // lists the valid types
    }

    @Test func generalPurposeSubagentIsRecognizedByDefault() async {
        // It inherits the parent's (scripted) model, so it loops once then finishes; the point is
        // only that the type is recognized — not rejected as unknown.
        let agent = createDeepAgent(
            model: FakeChatModel(answer: "done", toolCalls: [taskCall("anything", "general-purpose")])
        )
        let (ok, events) = await agent.collect([.human("go")])
        #expect(ok)
        let result = events.toolCompletedResults.first { $0.name == "task" }?.result ?? ""
        #expect(!result.lowercased().contains("unknown subagent"))
    }

    @Test func subagentRunsIsolatedWithOwnPromptNoParentHistoryAndNoTaskTool() async {
        // Record what the subagent's model actually saw, by attaching a recorder to the subagent.
        let recorder = RunRecorder()
        let iso = SubAgent(
            name: "iso", description: "isolated worker", systemPrompt: "SUB PROMPT",
            tools: [EchoTool()],
            model: FakeChatModel(answer: "x"),
            middleware: [RequestRecordingMiddleware(recorder: recorder)]
        )
        let agent = createDeepAgent(
            model: FakeChatModel(answer: "done", toolCalls: [taskCall("THE TASK", "iso")]),
            subagents: [iso],
            includeFilesystem: false
        ) // keep the subagent's recorded tool set focused
        _ = await agent.collect([.human("parent question with a secret")])

        let subPrompt = await recorder.systemPrompts.first ?? nil
        #expect(subPrompt?.contains("SUB PROMPT") == true)
        #expect(subPrompt?.contains("parent question") != true) // no parent context leaked
        let subTools = await recorder.toolNameSets.first ?? []
        #expect(subTools.contains("echo"))
        #expect(!subTools.contains("task")) // subagents can't recurse into more subagents
        let subMessageCount = await recorder.messageCounts.first ?? -1
        #expect(subMessageCount == 1) // only the delegated task, no parent history
    }
}
