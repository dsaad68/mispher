@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// `HumanInTheLoopMiddleware`: gated tools wait for the human decision and honor it
/// (approve / edit / reject / respond), ungated tools pass through untouched, and the
/// gate travels into subagents so delegation can't bypass it.
struct HumanInTheLoopMiddlewareTests {
    /// A scripted approval handler that records every request it was shown.
    private actor DecisionScript {
        private let decision: ToolApprovalDecision
        private(set) var requests: [ToolApprovalRequest] = []

        init(_ decision: ToolApprovalDecision) { self.decision = decision }

        func decide(_ request: ToolApprovalRequest) -> ToolApprovalDecision {
            requests.append(request)
            return decision
        }

        /// The handler to hand the middleware (a `@Sendable` closure over this actor).
        nonisolated var handler: ToolApprovalHandler {
            { await self.decide($0) }
        }
    }

    private func echoRequest(_ text: String = "hi") -> ToolCallRequest {
        ToolCallRequest(
            call: AgentToolCall(name: "echo", arguments: ["text": .string(text)]),
            state: AgentState()
        )
    }

    @Test func ungatedToolRunsWithoutAskingTheHuman() async throws {
        let script = DecisionScript(.reject(message: nil))
        let middleware = HumanInTheLoopMiddleware(
            interruptOn: ["other_tool": InterruptOnConfig()], approvalHandler: script.handler
        )
        let message = try await middleware.wrapToolCall(echoRequest()) { request in
            .tool("ran", toolCallID: request.call.id)
        }
        #expect(message.text == "ran")
        let requests = await script.requests
        #expect(requests.isEmpty) // never consulted
    }

    @Test func approveRunsTheCallUnchanged() async throws {
        let script = DecisionScript(.approve)
        let middleware = HumanInTheLoopMiddleware(
            interruptOn: ["echo": InterruptOnConfig()], approvalHandler: script.handler
        )
        let request = echoRequest()
        let message = try await middleware.wrapToolCall(request) { forwarded in
            .tool("ran: \(forwarded.call.describedArguments)", toolCallID: forwarded.call.id)
        }
        #expect(message.text == "ran: text: hi")
        #expect(message.toolCallID == request.call.id)
        let shown = try #require(await script.requests.first)
        #expect(shown.toolName == "echo")
        #expect(shown.description.contains("Tool execution requires approval"))
        #expect(shown.allowedDecisions == [.approve, .reject])
    }

    @Test func rejectShortCircuitsWithTheReason() async throws {
        let script = DecisionScript(.reject(message: "not that file"))
        let middleware = HumanInTheLoopMiddleware(
            interruptOn: ["echo": InterruptOnConfig()], approvalHandler: script.handler
        )
        let request = echoRequest()
        let message = try await middleware.wrapToolCall(request) { _ in
            Issue.record("the tool must not run on reject")
            return .tool("ran")
        }
        #expect(message.text.contains("rejected"))
        #expect(message.text.contains("not that file"))
        #expect(message.toolCallID == request.call.id) // still answers the original call
    }

    @Test func editRunsTheCallWithReplacedArguments() async throws {
        let script = DecisionScript(.edit(arguments: ["text": .string("EDITED")]))
        let middleware = HumanInTheLoopMiddleware(
            interruptOn: ["echo": InterruptOnConfig(allowedDecisions: [.approve, .edit, .reject])],
            approvalHandler: script.handler
        )
        let request = echoRequest("original")
        let message = try await middleware.wrapToolCall(request) { forwarded in
            #expect(forwarded.call.id == request.call.id) // same call, new args
            return .tool("ran: \(forwarded.call.describedArguments)", toolCallID: forwarded.call.id)
        }
        #expect(message.text == "ran: text: EDITED")
    }

    @Test func respondBecomesTheToolResultWithoutRunningIt() async throws {
        let script = DecisionScript(.respond(message: "the human's answer"))
        let middleware = HumanInTheLoopMiddleware(
            interruptOn: ["echo": InterruptOnConfig(allowedDecisions: [.approve, .respond])],
            approvalHandler: script.handler
        )
        let message = try await middleware.wrapToolCall(echoRequest()) { _ in
            Issue.record("the tool must not run on respond")
            return .tool("ran")
        }
        #expect(message.text == "the human's answer")
    }

    @Test func disallowedDecisionThrows() async throws {
        let script = DecisionScript(.respond(message: "x"))
        let middleware = HumanInTheLoopMiddleware(
            interruptOn: ["echo": InterruptOnConfig(allowedDecisions: [.approve, .reject])],
            approvalHandler: script.handler
        )
        await #expect(throws: HumanInTheLoopError.self) {
            _ = try await middleware.wrapToolCall(echoRequest()) { request in
                .tool("ran", toolCallID: request.call.id)
            }
        }
    }

    /// End-to-end through the ReAct loop: a denied call feeds the rejection back as the
    /// tool's result, and the run still finishes with a final answer.
    @Test func reactLoopFeedsRejectionBackAndCompletes() async throws {
        let script = DecisionScript(.reject(message: nil))
        let call = AgentToolCall(name: "echo", arguments: ["text": .string("hi")])
        let agent = createAgent(
            model: FakeChatModel(answer: "done without it", toolCalls: [call]),
            tools: [EchoTool()],
            middleware: [
                HumanInTheLoopMiddleware(
                    interruptOn: ["echo": InterruptOnConfig()], approvalHandler: script.handler
                )
            ]
        )
        let (ok, events) = await agent.collect([.human("go")])
        #expect(ok)
        #expect(events.finalAnswer == "done without it")
        let result = events.toolCompletedResults.first { $0.name == "echo" }?.result ?? ""
        #expect(result.contains("rejected"))
        let requests = await script.requests
        #expect(requests.count == 1)
    }

    /// The gate's system-prompt note travels with the middleware, naming the gated tools.
    @Test func systemPromptNamesTheGatedTools() async throws {
        let recorder = RunRecorder()
        let agent = createAgent(
            model: FakeChatModel(answer: "x"),
            tools: [EchoTool()],
            middleware: [
                HumanInTheLoopMiddleware(
                    interruptOn: ["echo": InterruptOnConfig()], approvalHandler: { _ in .approve }
                ),
                RequestRecordingMiddleware(recorder: recorder)
            ]
        )
        _ = await agent.collect([.human("hi")])
        let prompt = await (recorder.systemPrompts.first ?? nil) ?? ""
        #expect(prompt.contains("Tool approvals"))
        #expect(prompt.contains("`echo`"))
    }

    /// Delegation can't bypass the gate: `createDeepAgent` threads the same
    /// human-in-the-loop middleware into each subagent, so a subagent's `write_file`
    /// asks the human too — and a denial means the file is never written.
    @Test func subagentFileWriteIsGatedToo() async throws {
        let script = DecisionScript(.reject(message: nil))
        let backend = StateBackend()
        let writeCall = AgentToolCall(
            name: "write_file",
            arguments: ["file_path": .string("sub.txt"), "content": .string("nope")]
        )
        let worker = SubAgent(
            name: "worker", description: "writes a file", systemPrompt: "w",
            model: FakeChatModel(answer: "done", toolCalls: [writeCall])
        )
        let agent = createDeepAgent(
            model: FakeChatModel(
                answer: "finished",
                toolCalls: [
                    AgentToolCall(
                        name: "task",
                        arguments: [
                            "description": .string("write it"), "subagent_type": .string("worker")
                        ]
                    )
                ]
            ),
            subagents: [worker],
            backend: backend,
            interruptOn: ["write_file": InterruptOnConfig()],
            approvalHandler: script.handler,
            includeGeneralPurpose: false
        )
        let (ok, _) = await agent.collect([.human("go")])
        #expect(ok)
        let asked = await script.requests.map(\.toolName)
        #expect(asked == ["write_file"]) // asked once, from the subagent
        let written = await backend.read("sub.txt")
        #expect(written == nil) // denied → never written
    }

    /// Without an approval handler `createDeepAgent` registers no gate (deepagents'
    /// `interrupt_on` is likewise inert without a way to ask anyone).
    @Test func interruptOnWithoutHandlerIsInert() async throws {
        let backend = StateBackend()
        let call = AgentToolCall(
            name: "write_file",
            arguments: ["file_path": .string("f.txt"), "content": .string("v")]
        )
        let agent = createDeepAgent(
            model: FakeChatModel(answer: "done", toolCalls: [call]),
            backend: backend,
            interruptOn: ["write_file": InterruptOnConfig()]
        )
        _ = await agent.collect([.human("go")])
        let written = await backend.read("f.txt")
        #expect(written == "v")
    }
}
