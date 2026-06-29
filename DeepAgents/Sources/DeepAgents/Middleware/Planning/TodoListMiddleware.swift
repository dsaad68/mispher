import Foundation

/// One item on the agent's to-do list — mirrors LangChain's `Todo`.
public struct TodoItem: Sendable, Identifiable {
    public enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public let id = UUID()
    public var content: String
    public var status: Status

    public init(content: String, status: Status) {
        self.content = content
        self.status = status
    }
}

/// Planning middleware — Mispher's port of LangChain's `TodoListMiddleware`. It gives
/// the agent a `write_todos` tool to record and update a short plan for multi-step
/// tasks, and injects guidance on when to use it. The current list is surfaced to the
/// UI via `AgentEvent.todosUpdated`.
public struct TodoListMiddleware: AgentMiddleware {
    public init() {}
    public var name: String { "todo_list" }
    public var tools: [any AgentTool] { [WriteTodosTool()] }

    /// Append the planning guidance to the system prompt for every model call.
    public func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        let composed = [request.systemPrompt, Self.systemPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return try await handler(request.override(systemPrompt: composed))
    }

    /// Tool mechanics only — *when* to plan is policy and belongs to the agent's own
    /// system prompt (`AskPrompt` says skip it for single-step requests; `DeepScreenPrompt`
    /// mandates it always), so stating a policy here would contradict one of them.
    public static let systemPrompt = """
    ## Planning with `write_todos`
    For multi-step tasks, call `write_todos` to record a short plan, then keep it \
    current: mark exactly one item `in_progress` while you work it and `completed` \
    as soon as it's done. Pass `todos` as an array with one object per step — never \
    a single string with numbered steps. Each call replaces the entire list, so \
    always send the full set.
    """
}

/// The `write_todos` tool: replace the agent's plan with a new list of items.
public struct WriteTodosTool: AgentTool {
    public var name: String { "write_todos" }
    public var description: String {
        "Create or replace the task plan. Pass `todos` as an array with one object per step — "
            + "`{content, status}`. Use a separate item for each step; never put the whole plan in "
            + "one item or pass it as a single numbered string. Replaces the entire list."
    }

    public var parameters: [ToolParameter] {
        [
            .required(
                "todos",
                type: .array(
                    elementType: .object(properties: [
                        .required("content", type: .string, description: "What the task is."),
                        .required(
                            "status", type: .string,
                            description: "One of: pending, in_progress, completed.",
                            extraProperties: ["enum": ["pending", "in_progress", "completed"]]
                        )
                    ])
                ),
                description: "The full, ordered list of todo items."
            )
        ]
    }

    public func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        // Accept the common shapes models actually emit: an array of step objects, an
        // array of plain strings, a single object, or a single string.
        let rawItems: [AgentJSON]
        switch arguments["todos"] {
        case .array(let items): rawItems = items
        case .object: rawItems = [arguments["todos"]!]
        case .string(let text): rawItems = [.string(text)]
        default:
            return ToolOutput(
                "Error: provide `todos` as a list of steps, e.g. "
                    + "[{\"content\": \"Preheat oven\", \"status\": \"pending\"}]."
            )
        }

        let todos = rawItems.compactMap(Self.parseTodo)
        guard !todos.isEmpty || rawItems.isEmpty else {
            return ToolOutput(
                "Error: couldn't read any steps. Send a list like "
                    + "[{\"content\": \"Preheat oven\", \"status\": \"pending\"}]."
            )
        }

        let summary = todos.map { "- [\($0.status.rawValue)] \($0.content)" }.joined(separator: "\n")
        return ToolOutput(
            todos.isEmpty ? "Cleared the todo list." : "Updated todo list:\n\(summary)",
            stateUpdate: .set("todos", todos)
        )
    }

    /// Parse one todo from a plain string or an object with flexible content/status keys
    /// (models vary: "content"/"task"/"step", "status"/"state").
    static func parseTodo(_ value: AgentJSON) -> TodoItem? {
        switch value {
        case .string(let content):
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : TodoItem(content: trimmed, status: .pending)
        case .object(let object):
            let contentKeys = ["content", "task", "text", "step", "title", "description", "name"]
            guard
                let content = contentKeys.lazy.compactMap({ key -> String? in
                    if case .string(let value)? = object[key] { return value } else { return nil }
                }).first
            else { return nil }
            var status = TodoItem.Status.pending
            for key in ["status", "state"] {
                if case .string(let raw)? = object[key], let parsed = TodoItem.Status(rawValue: raw) {
                    status = parsed
                    break
                }
            }
            return TodoItem(content: content, status: status)
        default:
            return nil
        }
    }
}
