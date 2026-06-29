@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import MLXLMCommon
import Testing

/// Additional coverage of the agent core: argument rendering, multi-tool turns,
/// state-mutating and tool-filtering middleware, and small value types.
struct AgentCoreTests {
    @Test func describedArgumentsRendersEachType() {
        let call = AgentToolCall(
            name: "t",
            arguments: [
                "s": .string("hi"),
                "n": .int(3),
                "b": .bool(true),
                "arr": .array([.int(1), .int(2)])
            ]
        )
        let described = call.describedArguments
        #expect(described.contains("s: hi"))
        #expect(described.contains("n: 3"))
        #expect(described.contains("b: true"))
        #expect(described.contains("arr: [1, 2]"))
    }

    @Test func emptyArgumentsRenderEmptyString() {
        #expect(AgentToolCall(name: "t", arguments: [:]).describedArguments == "")
    }

    @Test func dispatchesMultipleToolCallsInOrder() async {
        let calls = [
            AgentToolCall(name: "echo", arguments: ["text": .string("one")]),
            AgentToolCall(name: "echo", arguments: ["text": .string("two")])
        ]
        let agent = createAgent(
            model: FakeChatModel(answer: "ok", toolCalls: calls), tools: [EchoTool()]
        )
        let (ok, events) = await agent.collect([.human("hi")])
        #expect(ok)
        #expect(events.toolStartedNames == ["echo", "echo"])
        #expect(events.toolCompletedResults.map(\.result) == ["echo: one", "echo: two"])
    }

    @Test func beforeModelCanMutateMessages() async {
        let recorder = RunRecorder()
        let agent = createAgent(
            model: FakeChatModel(answer: "x"),
            middleware: [PrependMessageMiddleware(), RequestRecordingMiddleware(recorder: recorder)]
        )
        _ = await agent.collect([.human("hi")])
        // The injected system message means the assembled request has 2 messages, not 1.
        #expect(await recorder.messageCounts == [2])
    }

    @Test func wrapModelCallCanFilterTools() async {
        let recorder = RunRecorder()
        let agent = createAgent(
            model: FakeChatModel(answer: "x"),
            tools: [EchoTool()],
            // Recorder is registered last so it sees the request after DropTools filters it.
            middleware: [DropToolsMiddleware(), RequestRecordingMiddleware(recorder: recorder)]
        )
        _ = await agent.collect([.human("hi")])
        #expect(await recorder.toolNameSets == [[]])
    }

    @Test func createAgentWithoutToolsOrMiddleware() async {
        let agent = createAgent(model: FakeChatModel(answer: "hi"))
        #expect(agent.tools.isEmpty)
        let (ok, events) = await agent.collect([.human("x")])
        #expect(ok)
        #expect(events.tokenText == "hi")
        #expect(events.toolStartedNames.isEmpty)
    }

    @Test func stateUpdateSetStoresValue() {
        let update = AgentStateUpdate.set("k", 42)
        #expect(update.values["k"] as? Int == 42)
    }

    @Test func describedArgumentsRendersNestedAndNull() {
        let call = AgentToolCall(
            name: "t",
            arguments: [
                "obj": .object(["a": .int(1)]),
                "nothing": .null,
                "d": .double(2.5)
            ]
        )
        let described = call.describedArguments
        #expect(described.contains("obj: {a: 1}"))
        #expect(described.contains("nothing: null"))
        #expect(described.contains("d: 2.5"))
    }

    @Test func noParameterToolSpecHasEmptyRequired() {
        let spec = ReadClipboardTool().toolSchema()
        let function = spec["function"] as? [String: any Sendable]
        #expect(function?["name"] as? String == "read_clipboard")
        let parameters = function?["parameters"] as? [String: any Sendable]
        #expect((parameters?["required"] as? [String])?.isEmpty == true)
    }
}

/// Test middleware: injects a system message before the model runs (exercises a
/// `beforeModel` hook that mutates the message list the model sees).
struct PrependMessageMiddleware: AgentMiddleware {
    func beforeModel(_ state: inout AgentState) async {
        state.messages.insert(.system("injected"), at: 0)
    }
}

/// Test middleware: strips all tools from the model request via `wrapModelCall`.
struct DropToolsMiddleware: AgentMiddleware {
    func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        try await handler(request.override(tools: []))
    }
}
