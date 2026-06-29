@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Testing

/// The agent-owned ReAct loop: structured message accumulation, per-round middleware,
/// `jump_to`, generic tool state updates, the iteration cap, and streaming labels. These
/// are the behaviors the old (loop-collapsed-into-the-model) design could not express.
struct ReactLoopTests {
    // MARK: - Message & tool-result gathering (A1/A2/A3)

    @Test func accumulatesStructuredToolExchangeWithIDs() async {
        let memory = InMemoryCheckpointer()
        let call = AgentToolCall(name: "echo", arguments: ["text": .string("hi")])
        let agent = createAgent(
            model: FakeChatModel(answer: "done", toolCalls: [call]),
            tools: [EchoTool()],
            memory: memory
        )

        _ = await agent.collect([.human("use it")], threadId: "t")

        let saved = await memory.load("t")
        #expect(saved.map(\.role) == [.human, .ai, .tool, .ai])
        // The AI turn records the tool call; the tool result links back by id.
        let aiCall = saved[1].toolCalls.first
        #expect(aiCall?.name == "echo")
        #expect(saved[2].toolCallID == aiCall?.id)
        #expect(saved[2].text == "echo: hi")
        #expect(saved[3].text == "done")
    }

    @Test func multipleToolResultsRecordedSeparatelyWithIDs() async {
        let c1 = AgentToolCall(name: "echo", arguments: ["text": .string("one")])
        let c2 = AgentToolCall(name: "echo", arguments: ["text": .string("two")])
        let memory = InMemoryCheckpointer()
        let agent = createAgent(
            model: FakeChatModel(answer: "ok", toolCalls: [c1, c2]),
            tools: [EchoTool()],
            memory: memory
        )

        _ = await agent.collect([.human("hi")], threadId: "t")

        let saved = await memory.load("t")
        #expect(saved.map(\.role) == [.human, .ai, .tool, .tool, .ai])
        #expect(saved[2].toolCallID == c1.id)
        #expect(saved[3].toolCallID == c2.id)
        #expect(saved[2].text == "echo: one")
        #expect(saved[3].text == "echo: two")
    }

    // MARK: - Per-round middleware (B1)

    @Test func modelHooksFirePerRound() async {
        let log = CallLog()
        let call = AgentToolCall(name: "echo", arguments: ["text": .string("x")])
        let agent = createAgent(
            model: FakeChatModel(answer: "done", toolCalls: [call]),
            tools: [EchoTool()],
            middleware: [RecordingMiddleware(label: "A", log: log)]
        )

        _ = await agent.collect([.human("hi")])

        let entries = await log.entries
        // Two rounds (tool round + final answer): per-model hooks fire twice…
        #expect(entries.filter { $0 == "A.beforeModel" }.count == 2)
        #expect(entries.filter { $0 == "A.afterModel" }.count == 2)
        #expect(entries.filter { $0 == "A.wrap.before" }.count == 2)
        #expect(entries.filter { $0 == "A.wrap.after" }.count == 2)
        // …while the agent-level hooks fire exactly once.
        #expect(entries.filter { $0 == "A.beforeAgent" }.count == 1)
        #expect(entries.filter { $0 == "A.afterAgent" }.count == 1)
    }

    // MARK: - Control flow: jump_to (C1)

    @Test func jumpToEndStopsTheRun() async {
        let call = AgentToolCall(name: "echo", arguments: ["text": .string("x")])
        let memory = InMemoryCheckpointer()
        let agent = createAgent(
            model: FakeChatModel(answer: "done", toolCalls: [call]),
            tools: [EchoTool()],
            middleware: [StopAfterModelMiddleware()],
            memory: memory
        )

        let (ok, events) = await agent.collect([.human("hi")], threadId: "t")

        #expect(ok)
        #expect(events.didComplete)
        #expect(events.toolStartedNames.isEmpty) // jumped to end before dispatching tools
        let saved = await memory.load("t")
        #expect(saved.map(\.role) == [.human, .ai]) // no tool turn ran
    }

    // MARK: - Generic tool state updates (C2) + visibility to later tools (B3)

    @Test func toolStateUpdateMergesAndIsVisibleToLaterTools() async {
        let set = AgentToolCall(name: "set_counter", arguments: [:])
        let read = AgentToolCall(name: "read_counter", arguments: [:])
        let model = FakeChatModel(turns: [
            .init(text: "", toolCalls: [set]),
            .init(text: "", toolCalls: [read]),
            .init(text: "done", toolCalls: [])
        ])
        let agent = createAgent(model: model, tools: [SetCounterTool(), ReadCounterTool()])

        let (ok, events) = await agent.collect([.human("go")])

        #expect(ok)
        // The non-"todos" state update merged into state.values and a later tool saw it.
        #expect(
            events.toolCompletedResults.contains {
                $0.name == "read_counter" && $0.result == "counter=7"
            }
        )
    }

    @Test func wrapToolCallSeesCurrentRoundState() async {
        let probe = StateProbe()
        let call = AgentToolCall(name: "echo", arguments: ["text": .string("x")])
        let agent = createAgent(
            model: FakeChatModel(answer: "done", toolCalls: [call]),
            tools: [EchoTool()],
            middleware: [ProbeToolMiddleware(probe: probe)]
        )

        _ = await agent.collect([.human("hi")])

        // The state handed to tool dispatch includes this round's AI tool-call message.
        #expect(await probe.sawAICall)
    }

    // MARK: - Iteration cap (C3)

    @Test func maxIterationsCapsTheLoop() async {
        let agent = createAgent(
            model: LoopingToolModel(toolName: "echo"),
            tools: [EchoTool()],
            maxIterations: 3
        )

        let (ok, events) = await agent.collect([.human("loop")])

        #expect(ok)
        #expect(events.didComplete)
        // A model that calls a tool every round is stopped after exactly maxIterations.
        #expect(events.toolStartedNames.count == 3)
        // Hitting the cap forces one last tool-less turn so the run still ends on a
        // final (no-tool) round rather than a dangling tool result.
        #expect(events.roundCompletions.last == false)
    }

    // MARK: - Duplicate-round guard

    @Test func repeatedIdenticalCallsForceFinalAnswer() async {
        // The model re-issues the identical call every round. Round 1 dispatches; the
        // round-2 repeat is NOT re-executed (it gets a redirect to the existing result);
        // the round-3 repeat forces a tool-less final answer.
        let agent = createAgent(
            model: StuckToolModel(toolName: "echo", finalAnswer: "forced answer"),
            tools: [EchoTool()],
            maxIterations: 10
        )

        let (ok, events) = await agent.collect([.human("loop")])

        #expect(ok)
        #expect(events.didComplete)
        #expect(events.toolStartedNames.count == 1) // the duplicate never re-executed
        let redirect = events.toolFailures.first { $0.name == "echo" }?.error ?? ""
        #expect(redirect.contains("already called"))
        #expect(events.finalAnswer == "forced answer")
    }

    @Test func legitimateRepeatWithDifferentArgumentsIsNotStopped() async {
        let c1 = AgentToolCall(name: "echo", arguments: ["text": .string("one")])
        let c2 = AgentToolCall(name: "echo", arguments: ["text": .string("two")])
        let c3 = AgentToolCall(name: "echo", arguments: ["text": .string("three")])
        let model = FakeChatModel(turns: [
            .init(text: "", toolCalls: [c1]),
            .init(text: "", toolCalls: [c2]),
            .init(text: "", toolCalls: [c3]),
            .init(text: "done", toolCalls: [])
        ])
        let agent = createAgent(model: model, tools: [EchoTool()])

        let (ok, events) = await agent.collect([.human("go")])

        #expect(ok)
        // Same tool, different arguments each round — the guard must not fire.
        #expect(events.toolStartedNames == ["echo", "echo", "echo"])
        #expect(events.finalAnswer == "done")
    }

    // MARK: - Malformed tool-call feedback

    @Test func malformedToolCallIsFedBackAndLoopContinues() async {
        let memory = InMemoryCheckpointer()
        let model = FakeChatModel(turns: [
            .init(text: "", toolCalls: [], malformedBlocks: ["echo(text=\"unterminated"]),
            .init(text: "done", toolCalls: [])
        ])
        let agent = createAgent(model: model, tools: [EchoTool()], memory: memory)

        let (ok, events) = await agent.collect([.human("go")], threadId: "t")

        #expect(ok)
        // The malformed round is NOT a final answer: it counts as a tool round and the
        // run continues to a real final answer.
        #expect(events.roundCompletions == [true, false])
        #expect(events.finalAnswer == "done")
        // The model received the parse error as a tool-role message.
        let saved = await memory.load("t")
        #expect(saved.map(\.role) == [.human, .ai, .tool, .ai])
        #expect(saved[2].text.contains("could not be parsed"))
    }

    // MARK: - Schema validation (pre-dispatch)

    @Test func missingRequiredParameterIsRejectedWithCorrection() async {
        // `echo` requires `text`; the call omits it. The tool must NOT run — the model
        // gets a correction as the tool result and can fix the call next round.
        let bad = AgentToolCall(name: "echo", arguments: [:])
        let good = AgentToolCall(name: "echo", arguments: ["text": .string("hi")])
        let model = FakeChatModel(turns: [
            .init(text: "", toolCalls: [bad]),
            .init(text: "", toolCalls: [good]),
            .init(text: "done", toolCalls: [])
        ])
        let agent = createAgent(model: model, tools: [EchoTool()])

        let (ok, events) = await agent.collect([.human("go")])

        #expect(ok)
        let error = events.toolFailures.first?.error ?? ""
        #expect(error.contains("missing required parameter"))
        #expect(error.contains("text"))
        // The corrected retry executed normally.
        #expect(events.toolCompletedResults.map(\.result) == ["echo: hi"])
        #expect(events.finalAnswer == "done")
    }

    @Test func enumViolationIsRejectedWithAllowedValues() async {
        let call = AgentToolCall(name: "pick", arguments: ["mode": .string("sideways")])
        let agent = createAgent(
            model: FakeChatModel(answer: "done", toolCalls: [call]),
            tools: [EnumTool()]
        )

        let (ok, events) = await agent.collect([.human("go")])

        #expect(ok)
        let error = events.toolFailures.first?.error ?? ""
        #expect(error.contains("sideways")) // names the bad value…
        #expect(error.contains("up") && error.contains("down")) // …and the valid ones
        #expect(events.toolCompletedResults.isEmpty) // the tool never ran
    }

    @Test func lenientArgumentShapesStillReachTheTool() async {
        // `write_todos` deliberately coerces loose shapes (a plain string for `todos`)
        // inside `execute` — validation must stay conservative and let those through.
        let call = AgentToolCall(name: "write_todos", arguments: ["todos": .string("one step")])
        let agent = createAgent(
            model: FakeChatModel(answer: "done", toolCalls: [call]),
            tools: [WriteTodosTool()]
        )

        let (ok, events) = await agent.collect([.human("go")])

        #expect(ok)
        #expect(events.toolFailures.isEmpty)
        #expect(events.toolCompletedResults.first?.result.contains("one step") == true)
    }

    @Test func unknownToolErrorIsJSONAndListsAvailableTools() async {
        let call = AgentToolCall(name: "ghost", arguments: [:])
        let agent = createAgent(
            model: FakeChatModel(answer: "after", toolCalls: [call]),
            tools: [EchoTool()]
        )

        let (ok, events) = await agent.collect([.human("go")])

        #expect(ok)
        let error = events.toolFailures.first?.error ?? ""
        // The docs/cookbook error shape: a JSON object the model can read back.
        #expect(error.hasPrefix("{") && error.contains("\"error\""))
        #expect(error.contains("ghost"))
        #expect(error.contains("echo")) // tells the model what it CAN call
    }

    // MARK: - Tool-result truncation

    @Test func oversizedToolResultIsTruncated() async {
        let long = String(repeating: "x", count: ReactAgent.maxToolResultCharacters + 500)
        let call = AgentToolCall(name: "echo", arguments: ["text": .string(long)])
        let agent = createAgent(
            model: FakeChatModel(answer: "done", toolCalls: [call]),
            tools: [EchoTool()]
        )

        let (ok, events) = await agent.collect([.human("go")])

        #expect(ok)
        let result = events.toolCompletedResults.first?.result ?? ""
        #expect(result.contains("[Result truncated"))
        // Truncated to the cap plus the short trailing note.
        #expect(result.count < ReactAgent.maxToolResultCharacters + 200)
    }

    // MARK: - Streaming labels (interim vs final)

    @Test func streamingLabelsInterimVsFinalRounds() async {
        let call = AgentToolCall(name: "echo", arguments: ["text": .string("x")])
        // Round 1 emits interim text AND a tool call; round 2 is the final answer.
        let model = FakeChatModel(turns: [
            .init(text: "thinking", toolCalls: [call]),
            .init(text: "final answer", toolCalls: [])
        ])
        let agent = createAgent(model: model, tools: [EchoTool()])

        let (ok, events) = await agent.collect([.human("hi")])

        #expect(ok)
        #expect(events.roundCompletions == [true, false])
        #expect(events.finalAnswer == "final answer") // interim "thinking" excluded
        #expect(events.tokenText == "thinkingfinal answer") // raw stream still has both
    }
}

// MARK: - Test fixtures

/// Test middleware: ends the run from `afterModel` via `jump_to`.
private struct StopAfterModelMiddleware: AgentMiddleware {
    func afterModel(_ state: inout AgentState) async { state.jumpTo = .end }
}

/// Test tool with an `enum`-constrained parameter, for schema-validation tests.
private struct EnumTool: AgentTool {
    var name: String { "pick" }
    var description: String { "Pick a direction." }
    var parameters: [ToolParameter] {
        [
            .required(
                "mode", type: .string, description: "Direction.",
                extraProperties: ["enum": ["up", "down"]]
            )
        ]
    }

    func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        ToolOutput("picked")
    }
}

/// Test tool: writes a non-"todos" key into agent state.
private struct SetCounterTool: AgentTool {
    var name: String { "set_counter" }
    var description: String { "Set the counter to 7." }
    func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        ToolOutput("set", stateUpdate: .set("counter", 7))
    }
}

/// Test tool: reads the counter back out of agent state.
private struct ReadCounterTool: AgentTool {
    var name: String { "read_counter" }
    var description: String { "Read the counter from state." }
    func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        ToolOutput("counter=\(context.state.values["counter"] as? Int ?? -1)")
    }
}

private actor StateProbe {
    private(set) var sawAICall = false
    func mark(_ value: Bool) { sawAICall = sawAICall || value }
}

/// Test middleware: from `wrapToolCall`, checks the dispatched state already holds an AI
/// message carrying tool calls (proving the tool sees the current round's exchange).
private struct ProbeToolMiddleware: AgentMiddleware {
    let probe: StateProbe
    func wrapToolCall(
        _ request: ToolCallRequest,
        _ handler: (ToolCallRequest) async throws -> AgentMessage
    ) async throws -> AgentMessage {
        let sawAI = request.state.messages.contains { !$0.toolCalls.isEmpty }
        await probe.mark(sawAI)
        return try await handler(request)
    }
}
