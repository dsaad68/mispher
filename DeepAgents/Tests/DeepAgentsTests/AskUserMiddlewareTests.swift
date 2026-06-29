@testable import DeepAgents
import Foundation
import Testing

/// `AskUserMiddleware`: the `ask_user` tool parses the model's questions, suspends on the host
/// handler, and folds the answers back as a `Q:/A:` tool result - with validation failures and
/// cancel/error responses surfaced explicitly so the model never sees a silent gap.
struct AskUserMiddlewareTests {
    /// A scripted ask-user handler that records every request it was shown and returns a fixed reply.
    private actor AnswerScript {
        private let response: AskUserResponse
        private(set) var requests: [AskUserRequest] = []

        init(_ response: AskUserResponse) { self.response = response }

        func answer(_ request: AskUserRequest) -> AskUserResponse {
            requests.append(request)
            return response
        }

        /// The handler to hand the tool/middleware (a `@Sendable` closure over this actor).
        nonisolated var handler: AskUserHandler {
            { await self.answer($0) }
        }
    }

    private func question(_ text: String, type: String, choices: [String]? = nil) -> AgentJSON {
        var object: [String: AgentJSON] = ["question": .string(text), "type": .string(type)]
        if let choices { object["choices"] = .array(choices.map { .string($0) }) }
        return .object(object)
    }

    @Test func middlewareContributesAskUserToolWithQuestionsSchema() throws {
        let middleware = AskUserMiddleware(handler: { _ in .cancelled })
        let tool = try #require(middleware.tools.first)
        #expect(tool.name == "ask_user")
        let questions = try #require(tool.parameters.first)
        #expect(questions.name == "questions")
        #expect(questions.isRequired)
        guard case .array = questions.type else {
            Issue.record("`questions` must be an array parameter")
            return
        }
    }

    @Test func answeredFormatsQAndAPairs() async throws {
        let script = AnswerScript(.answered(["PostgreSQL", "Alembic"]))
        let tool = AskUserTool(handler: script.handler)
        let output = try await tool.execute(
            ["questions": .array([
                question("Which database?", type: "multiple_choice", choices: ["PostgreSQL", "SQLite"]),
                question("Migration tool?", type: "text")
            ])],
            ToolContext()
        )
        #expect(output.content == "Q: Which database?\nA: PostgreSQL\n\nQ: Migration tool?\nA: Alembic")
        let request = try #require(await script.requests.first)
        #expect(request.questions.count == 2)
        #expect(request.questions[0].type == .multipleChoice)
        #expect(request.questions[0].choices.map(\.value) == ["PostgreSQL", "SQLite"])
        #expect(request.questions[1].type == .text)
    }

    @Test func cancelledSynthesizesCancelledAnswers() async throws {
        let script = AnswerScript(.cancelled)
        let tool = AskUserTool(handler: script.handler)
        let output = try await tool.execute(
            ["questions": .array([question("A?", type: "text"), question("B?", type: "text")])],
            ToolContext()
        )
        #expect(output.content == "Q: A?\nA: (cancelled)\n\nQ: B?\nA: (cancelled)")
    }

    @Test func errorSynthesizesErrorAnswers() async throws {
        let script = AnswerScript(.error("no tty"))
        let tool = AskUserTool(handler: script.handler)
        let output = try await tool.execute(
            ["questions": .array([question("A?", type: "text")])],
            ToolContext()
        )
        #expect(output.content == "Q: A?\nA: (error: no tty)")
    }

    @Test func shortAnswerListIsPaddedWithNoAnswer() async throws {
        let script = AnswerScript(.answered(["only one"]))
        let tool = AskUserTool(handler: script.handler)
        let output = try await tool.execute(
            ["questions": .array([question("A?", type: "text"), question("B?", type: "text")])],
            ToolContext()
        )
        #expect(output.content == "Q: A?\nA: only one\n\nQ: B?\nA: (no answer)")
    }

    @Test func emptyQuestionsReturnsErrorWithoutAsking() async throws {
        let script = AnswerScript(.answered([]))
        let tool = AskUserTool(handler: script.handler)
        let output = try await tool.execute(["questions": .array([])], ToolContext())
        #expect(output.content.contains("at least one question"))
        #expect(await script.requests.isEmpty)
    }

    @Test func multipleChoiceWithoutChoicesReturnsError() async throws {
        let script = AnswerScript(.cancelled)
        let tool = AskUserTool(handler: script.handler)
        let output = try await tool.execute(
            ["questions": .array([question("Pick one", type: "multiple_choice")])],
            ToolContext()
        )
        #expect(output.content.contains("requires a non-empty 'choices' list"))
        #expect(await script.requests.isEmpty)
    }

    @Test func textWithChoicesReturnsError() async throws {
        let script = AnswerScript(.cancelled)
        let tool = AskUserTool(handler: script.handler)
        let output = try await tool.execute(
            ["questions": .array([question("Your name?", type: "text", choices: ["X"])])],
            ToolContext()
        )
        #expect(output.content.contains("must not define 'choices'"))
        #expect(await script.requests.isEmpty)
    }

    @Test func infersMultipleChoiceFromBareStringChoices() async throws {
        let script = AnswerScript(.answered(["X"]))
        let tool = AskUserTool(handler: script.handler)
        // No explicit `type`, choices given as bare strings - inferred as multiple_choice.
        _ = try await tool.execute(
            ["questions": .array([.object([
                "question": .string("Pick one"),
                "choices": .array([.string("X"), .string("Y")])
            ])])],
            ToolContext()
        )
        let request = try #require(await script.requests.first)
        #expect(request.questions.first?.type == .multipleChoice)
        #expect(request.questions.first?.choices.map(\.value) == ["X", "Y"])
    }

    @Test func multiSelectQuestionParsesWithChoices() async throws {
        let script = AnswerScript(.answered(["B, C"])) // a multi_select answer is the chosen values joined
        let tool = AskUserTool(handler: script.handler)
        let output = try await tool.execute(
            ["questions": .array([question("Pick some", type: "multi_select", choices: ["A", "B", "C"])])],
            ToolContext()
        )
        #expect(output.content == "Q: Pick some\nA: B, C")
        let request = try #require(await script.requests.first)
        #expect(request.questions.first?.type == .multiSelect)
        #expect(request.questions.first?.choices.map(\.value) == ["A", "B", "C"])
    }

    @Test func multiSelectWithoutChoicesReturnsError() async throws {
        let script = AnswerScript(.cancelled)
        let tool = AskUserTool(handler: script.handler)
        let output = try await tool.execute(
            ["questions": .array([question("Pick some", type: "multi_select")])],
            ToolContext()
        )
        #expect(output.content.contains("requires a non-empty 'choices' list"))
        #expect(await script.requests.isEmpty)
    }

    @Test func wrapModelCallAppendsAskUserGuidance() async throws {
        let middleware = AskUserMiddleware(handler: { _ in .cancelled })
        var captured: String?
        _ = try await middleware.wrapModelCall(
            ModelRequest(messages: [], systemPrompt: "BASE", tools: [])
        ) { request in
            captured = request.systemPrompt
            return ModelResponse(message: .ai("x"))
        }
        let prompt = try #require(captured)
        #expect(prompt.hasPrefix("BASE"))
        #expect(prompt.contains("## `ask_user`"))
    }

    /// End-to-end through the ReAct loop: the model calls `ask_user`, the handler answers, and the
    /// answers come back as the tool result while the run completes with a final answer.
    @Test func reactLoopSurfacesQuestionsAndFoldsAnswersBack() async throws {
        let script = AnswerScript(.answered(["SQLite"]))
        let call = AgentToolCall(
            name: "ask_user",
            arguments: ["questions": .array([question("Which DB?", type: "text")])]
        )
        let agent = createAgent(
            model: FakeChatModel(answer: "using SQLite", toolCalls: [call]),
            middleware: [AskUserMiddleware(handler: script.handler)]
        )
        let (ok, events) = await agent.collect([.human("go")])
        #expect(ok)
        #expect(events.finalAnswer == "using SQLite")
        let result = events.toolCompletedResults.first { $0.name == "ask_user" }?.result ?? ""
        #expect(result.contains("Q: Which DB?"))
        #expect(result.contains("A: SQLite"))
        #expect(await script.requests.count == 1)
    }
}
