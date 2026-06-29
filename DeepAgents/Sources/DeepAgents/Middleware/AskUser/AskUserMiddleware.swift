import Foundation

/// Ask-user middleware - Mispher's port of deepagents' `AskUserMiddleware`. It gives the agent an
/// `ask_user` tool to pose clarifying questions to the user mid-run, and injects guidance on when to
/// use it (sparingly - only for input it genuinely can't infer from context).
///
/// deepagents implements the tool body with a LangGraph `interrupt`, because its runs are
/// checkpointed and resumed across processes. Mispher's loop is in-process, so - exactly like
/// ``HumanInTheLoopMiddleware`` does for approvals - the `ask_user` tool suspends on the async
/// `handler` the host provides until the user answers, then resumes with their answers as the tool
/// result. Registered on the main agent only: asking the user is a top-level concern, not something a
/// delegated subagent should do mid-subtask.
public struct AskUserMiddleware: AgentMiddleware {
    let handler: AskUserHandler

    public init(handler: @escaping AskUserHandler) {
        self.handler = handler
    }

    public var name: String { "ask_user" }
    public var tools: [any AgentTool] { [AskUserTool(handler: handler)] }

    /// Append the ask_user guidance to the system prompt for every model call - same seam
    /// ``TodoListMiddleware`` uses for its planning guidance.
    public func wrapModelCall(
        _ request: ModelRequest,
        _ next: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        let composed = [request.systemPrompt, Self.systemPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return try await next(request.override(systemPrompt: composed))
    }

    /// deepagents' `ASK_USER_SYSTEM_PROMPT`, telling the model how and when to reach for the tool.
    static let systemPrompt = """
    ## `ask_user`

    You have access to the `ask_user` tool to ask the user questions when you need clarification or input.
    Use this tool sparingly - only when you genuinely need information from the user that you cannot \
    determine from context.

    When using `ask_user`:
    - Be concise and specific with your questions
    - Use multiple choice when there are clear options to choose from
    - Use text input when you need free-form responses
    - Group related questions into a single ask_user call rather than making multiple calls
    - Never ask questions you can answer yourself from the available context
    """

    /// deepagents' `ASK_USER_TOOL_DESCRIPTION` (em dash swapped for " - " per the repo's UI-string
    /// convention).
    static let toolDescription = """
    Ask the user one or more questions when you need clarification or input before proceeding.

    Each question can be one of:
    - "text": Free-form text response from the user
    - "multiple_choice": User selects exactly one of the predefined options (an "Other" option is always available)
    - "multi_select": User selects one or more of the predefined options (an "Other" option is always available)

    For "multiple_choice" and "multi_select" questions, provide a list of choices. The user can pick \
    from them or type a custom answer via the "Other" option. A "multi_select" answer comes back as the \
    chosen values joined by ", ".

    By default all questions are required. Set "required" to false for optional questions that the user \
    can skip. Do not include "(required)", "(optional)", "- optional", or similar annotations in the \
    question text - the UI renders that separately based on the "required" field.

    Use this tool when:
    - You need clarification on ambiguous requirements
    - You want the user to choose between multiple valid approaches
    - You need specific information only the user can provide
    - You want to confirm a plan before executing it

    Do NOT use this tool for:
    - Simple yes/no confirmations (just proceed with your best judgment)
    - Questions you can answer yourself from context
    - Trivial decisions that don't meaningfully affect the outcome
    """
}

/// The `ask_user` tool: pose one or more questions to the user and return their answers as a tool
/// result. Built like ``WriteTodosTool`` (a nested array-of-object schema with forgiving parsing); it
/// suspends on the middleware's ``AskUserHandler`` while the user answers.
public struct AskUserTool: AgentTool {
    let handler: AskUserHandler

    public init(handler: @escaping AskUserHandler) { self.handler = handler }

    public var name: String { "ask_user" }
    public var description: String { AskUserMiddleware.toolDescription }

    public var parameters: [ToolParameter] {
        [
            .required(
                "questions",
                type: .array(
                    elementType: .object(properties: [
                        .required(
                            "question", type: .string,
                            description: "The question text to display."
                        ),
                        .required(
                            "type", type: .string,
                            description: "\"text\" for a free-form answer, \"multiple_choice\" to pick one option, "
                                + "or \"multi_select\" to pick one or more.",
                            extraProperties: ["enum": ["text", "multiple_choice", "multi_select"]]
                        ),
                        .optional(
                            "choices",
                            type: .array(elementType: .object(properties: [
                                .required("value", type: .string, description: "The display label for this choice.")
                            ])),
                            description: "The options for a multiple_choice question. Omit for text questions."
                        ),
                        .optional(
                            "required", type: .bool,
                            description: "Whether the user must answer. Defaults to true."
                        )
                    ])
                ),
                description: "The questions to ask. Provide at least one."
            )
        ]
    }

    public func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        let questions = AskUser.parseQuestions(arguments["questions"])
        do {
            try AskUser.validate(questions)
        } catch {
            return ToolOutput(ReactAgent.errorJSON(error.localizedDescription))
        }
        let response = await handler(AskUserRequest(questions: questions))
        return ToolOutput(AskUser.format(questions: questions, response: response))
    }
}
