@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import MLXLMCommon
import Testing

/// The to-do planning middleware: `write_todos` parsing, prompt injection, and the
/// `todosUpdated` event surfaced to the UI.
struct TodoListMiddlewareTests {
    private func todosArg(_ items: [(String, String)]) -> AgentJSON {
        .array(
            items.map { content, status in
                .object(["content": .string(content), "status": .string(status)])
            }
        )
    }

    @Test func writeTodosParsesContentAndStatus() async throws {
        let args: [String: AgentJSON] = [
            "todos": todosArg([("write tests", "in_progress"), ("ship", "pending")])
        ]
        let output = try await WriteTodosTool().execute(args, ToolContext())
        let todos = try #require(output.stateUpdate?.values["todos"] as? [TodoItem])
        #expect(todos.count == 2)
        #expect(todos[0].content == "write tests")
        #expect(todos[0].status == .inProgress)
        #expect(todos[1].status == .pending)
        #expect(output.content.contains("in_progress"))
    }

    @Test func writeTodosRejectsUnparseableInput() async throws {
        let output = try await WriteTodosTool().execute(["todos": .int(5)], ToolContext())
        #expect(output.stateUpdate == nil)
        #expect(output.content.contains("Error"))
    }

    @Test func writeTodosAcceptsArrayOfStrings() async throws {
        let args: [String: AgentJSON] = ["todos": .array([.string("step one"), .string("step two")])]
        let output = try await WriteTodosTool().execute(args, ToolContext())
        let todos = try #require(output.stateUpdate?.values["todos"] as? [TodoItem])
        #expect(todos.map(\.content) == ["step one", "step two"])
        #expect(todos.allSatisfy { $0.status == .pending })
    }

    @Test func writeTodosAcceptsFlexibleKeys() async throws {
        let args: [String: AgentJSON] = [
            "todos": .array([.object(["task": .string("do it"), "state": .string("completed")])])
        ]
        let output = try await WriteTodosTool().execute(args, ToolContext())
        let todos = try #require(output.stateUpdate?.values["todos"] as? [TodoItem])
        #expect(todos.first?.content == "do it")
        #expect(todos.first?.status == .completed)
    }

    @Test func middlewareAppendsPlanningPromptToSystemPrompt() async {
        let recorder = RunRecorder()
        let agent = createAgent(
            model: FakeChatModel(answer: "x"),
            systemPrompt: "BASE",
            // Recorder last so it sees the prompt after TodoListMiddleware composes it.
            middleware: [TodoListMiddleware(), RequestRecordingMiddleware(recorder: recorder)]
        )
        _ = await agent.collect([.human("hi")])
        let prompt = await recorder.systemPrompts.first ?? nil
        #expect(prompt?.contains("BASE") == true)
        #expect(prompt?.contains("write_todos") == true)
    }

    @Test func writeTodosAcceptsSingleObject() async throws {
        let args: [String: AgentJSON] = [
            "todos": .object(["content": .string("only step"), "status": .string("pending")])
        ]
        let output = try await WriteTodosTool().execute(args, ToolContext())
        let todos = try #require(output.stateUpdate?.values["todos"] as? [TodoItem])
        #expect(todos.map(\.content) == ["only step"])
    }

    @Test func writeTodosAcceptsSingleString() async throws {
        let output = try await WriteTodosTool().execute(["todos": .string("just one")], ToolContext())
        let todos = try #require(output.stateUpdate?.values["todos"] as? [TodoItem])
        #expect(todos.map(\.content) == ["just one"])
    }

    @Test func writeTodosEmptyArrayClears() async throws {
        let output = try await WriteTodosTool().execute(["todos": .array([])], ToolContext())
        let todos = try #require(output.stateUpdate?.values["todos"] as? [TodoItem])
        #expect(todos.isEmpty)
        #expect(output.content.lowercased().contains("clear"))
    }

    @Test func writeTodosSkipsItemsWithoutContent() async throws {
        let args: [String: AgentJSON] = [
            "todos": .array([
                .object(["status": .string("pending")]), // no content → skipped
                .string("valid")
            ])
        ]
        let output = try await WriteTodosTool().execute(args, ToolContext())
        let todos = try #require(output.stateUpdate?.values["todos"] as? [TodoItem])
        #expect(todos.map(\.content) == ["valid"])
    }

    @Test func agentEmitsTodosUpdatedWhenToolRuns() async {
        let call = AgentToolCall(
            name: "write_todos", arguments: ["todos": todosArg([("a", "completed")])]
        )
        let agent = createAgent(
            model: FakeChatModel(answer: "done", toolCalls: [call]),
            middleware: [TodoListMiddleware()]
        )
        let (ok, events) = await agent.collect([.human("plan it")])
        #expect(ok)
        let updates = events.todoUpdates
        #expect(updates.count == 1)
        #expect(updates.first?.first?.content == "a")
        #expect(updates.first?.first?.status == .completed)
    }
}
