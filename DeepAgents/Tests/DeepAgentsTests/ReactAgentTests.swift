@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import MLXLMCommon
import Testing

/// The ReAct run loop: streaming, tool dispatch, tool merging, and error recovery.
struct ReactAgentTests {
    @Test func streamsAnswerTokensAndCompletes() async {
        let agent = createAgent(model: FakeChatModel(answer: "hello world"))
        let (ok, events) = await agent.collect([.human("hi")])
        #expect(ok)
        #expect(events.tokenText == "hello world")
        #expect(events.didComplete)
        #expect(!events.didFail)
    }

    @Test func createAgentMergesUserAndMiddlewareTools() {
        let agent = createAgent(
            model: FakeChatModel(),
            tools: [EchoTool()],
            middleware: [TodoListMiddleware(), ClipboardMiddleware(), UtilityMiddleware()]
        )
        #expect(
            agent.tools.map(\.name) == [
                "echo", "write_todos", "read_clipboard", "write_clipboard",
                "current_datetime", "calculator"
            ]
        )
    }

    @Test func dispatchesToolAndStreamsToolEvents() async {
        let call = AgentToolCall(name: "echo", arguments: ["text": .string("hi")])
        let agent = createAgent(
            model: FakeChatModel(answer: "done", toolCalls: [call]),
            tools: [EchoTool()]
        )
        let (ok, events) = await agent.collect([.human("use the tool")])
        #expect(ok)
        #expect(events.toolStartedNames == ["echo"])
        #expect(events.toolStarts.first?.input == "text: hi") // input surfaced to the UI
        #expect(events.toolCompletedResults.first?.name == "echo")
        #expect(events.toolCompletedResults.first?.result == "echo: hi")
        #expect(events.tokenText == "done")
    }

    @Test func unknownToolReportsFailureButRunSucceeds() async {
        let call = AgentToolCall(name: "ghost", arguments: [:])
        // No tools registered, so the model's call can't be resolved.
        let agent = createAgent(model: FakeChatModel(answer: "after", toolCalls: [call]))
        let (ok, events) = await agent.collect([.human("hi")])
        #expect(ok) // the run still completes; the model receives the error text
        #expect(events.toolFailedNames == ["ghost"])
        #expect(events.tokenText == "after")
    }

    @Test func throwingToolIsRecovered() async {
        let call = AgentToolCall(name: "boom", arguments: [:])
        let agent = createAgent(
            model: FakeChatModel(answer: "recovered", toolCalls: [call]),
            tools: [FailingTool()]
        )
        let (ok, events) = await agent.collect([.human("hi")])
        #expect(ok)
        #expect(events.toolFailedNames == ["boom"])
        #expect(events.tokenText == "recovered")
    }
}
