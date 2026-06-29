import Foundation

/// Subagent (delegation) middleware — Mispher's port of deepagents' `SubAgentMiddleware`. It
/// contributes a single `task` tool that lets the main agent hand an isolated subtask to a named
/// subagent. Each subagent runs as its own `ReactAgent` with a fresh conversation, so its work
/// never clutters the main agent's context; only its final answer comes back as the tool result.
///
/// A built-in **general-purpose** subagent is registered by default (like deepagents): it inherits
/// the deep agent's model and base tools and handles arbitrary delegated work. Custom subagents are
/// added via `subagents`.
public struct SubAgentMiddleware: AgentMiddleware {
    /// The model a subagent uses when it doesn't specify its own.
    let model: any ChatModel
    /// The deep agent's own tools — inherited by subagents whose `tools` is `nil`, and by the
    /// general-purpose subagent. This deliberately does NOT include the `task` tool (that's
    /// contributed here, not part of the base set), so a subagent can never spawn more subagents.
    let baseTools: [any AgentTool]
    /// The shared filesystem backend, threaded into each subagent so they see the same files.
    let backend: (any FilesystemBackend)?
    /// The parent's human-in-the-loop gate, threaded into each subagent so a delegated
    /// subtask can't run an approval-gated tool without asking the user.
    let humanInTheLoop: HumanInTheLoopMiddleware?
    /// The resolved registry: the general-purpose subagent first (if enabled), then the custom ones.
    let registry: [SubAgent]

    init(
        model: any ChatModel,
        baseTools: [any AgentTool] = [],
        subagents: [SubAgent] = [],
        backend: (any FilesystemBackend)? = nil,
        humanInTheLoop: HumanInTheLoopMiddleware? = nil,
        includeGeneralPurpose: Bool = true
    ) {
        self.model = model
        self.baseTools = baseTools
        self.backend = backend
        self.humanInTheLoop = humanInTheLoop
        registry = (includeGeneralPurpose ? [Self.generalPurpose] : []) + subagents
    }

    public var name: String { "subagents" }
    public var tools: [any AgentTool] {
        [
            TaskTool(
                registry: registry, model: model, baseTools: baseTools,
                backend: backend, humanInTheLoop: humanInTheLoop
            )
        ]
    }

    /// Tell the main agent which subagents it can delegate to.
    public func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        let composed = [request.systemPrompt, Self.guidance(for: registry)]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return try await handler(request.override(systemPrompt: composed))
    }

    /// The built-in general-purpose subagent: inherits the parent's model and base tools.
    static let generalPurpose = SubAgent(
        name: "general-purpose",
        description: "General-purpose agent for arbitrary multi-step subtasks. Use it to silo "
            + "isolated work (research, drafting, multi-step lookups) off your main context. It has "
            + "the same tools you do.",
        systemPrompt: """
        You are a focused subagent handling one delegated task. Do exactly what was asked, using \
        your tools as needed, and finish with a single clear, self-contained answer the calling \
        agent can use directly. You won't be asked follow-up questions, so don't ask any — return \
        your best complete result.
        """
    )

    /// Build the system-prompt note that lists the available subagents.
    static func guidance(for registry: [SubAgent]) -> String {
        let list = registry.map { "- `\($0.name)`: \($0.description)" }.joined(separator: "\n")
        return """
        ## Delegating with `task`
        For isolated, multi-step subtasks, call `task` with a thorough `description` and the \
        `subagent_type` of the right subagent below. The subagent runs on its own and returns a \
        single final result; it can't ask you follow-ups, so give it everything it needs.
        Available subagents:
        \(list)
        """
    }
}

/// The `task` tool: delegate a subtask to a named subagent and return its final result. Spawning a
/// child `ReactAgent` here (rather than threading the call through the parent's loop) is what gives
/// subagents their isolated context — the child sees only the delegated task, never the parent's
/// conversation.
public struct TaskTool: AgentTool {
    let registry: [SubAgent]
    let model: any ChatModel
    let baseTools: [any AgentTool]
    let backend: (any FilesystemBackend)?
    let humanInTheLoop: HumanInTheLoopMiddleware?

    public var name: String { "task" }
    public var description: String {
        let list = registry.map { "\($0.name) (\($0.description))" }.joined(separator: "; ")
        return "Delegate an isolated subtask to a specialized subagent, which runs on its own and "
            + "returns a single final result. Available subagent_type values: \(list)."
    }

    public var parameters: [ToolParameter] {
        [
            .required(
                "description", type: .string,
                description: "The full task for the subagent, with all the context it needs "
                    + "(it sees nothing else)."
            ),
            .required(
                "subagent_type", type: .string,
                description: "Which subagent to delegate to.",
                extraProperties: ["enum": registry.map(\.name)]
            ),
            .optional(
                "window", type: .int,
                description: "Optional. To analyze one specific open window, pass its number from "
                    + "take_window_screenshots; only that window's screenshot is given to the "
                    + "subagent. Omit to use the most recent take_screenshot capture."
            )
        ]
    }

    /// Parse a 1-based window number a planner may emit as an int, a double, or a numeric string.
    /// A non-integral double (e.g. 1.9) is rejected rather than truncated, so the addressed window
    /// is never ambiguous; `Int(_:)` likewise rejects a non-integer string.
    private static func windowNumber(_ value: AgentJSON?) -> Int? {
        switch value {
        case .int(let number): return number
        case .double(let number): return number.rounded() == number ? Int(number) : nil
        case .string(let text): return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard case .string(let task)? = arguments["description"], !task.isEmpty else {
            return ToolOutput("Error: `description` is required.")
        }
        guard case .string(let type)? = arguments["subagent_type"] else {
            return ToolOutput("Error: `subagent_type` is required.")
        }
        guard let subagent = registry.first(where: { $0.name == type }) else {
            let names = registry.map(\.name).joined(separator: ", ")
            return ToolOutput(
                "Error: unknown subagent '\(type)'. Available subagent_type values: \(names)."
            )
        }

        // If the parent captured a screenshot it can't view itself (the deep agent's blind text
        // planner attaches `ScreenshotMiddleware(attachToConversation: false)`), forward that image
        // into the subagent's first turn so a vision subagent actually sees it. Harmless for a text
        // subagent — `renderMessages` drops images unless its model is a VLM.
        //
        // Two capture sources: a `window` number addresses one entry from `take_window_screenshots`
        // (so the planner can analyze each window in turn, one delegation per window, at full
        // resolution); otherwise the single most recent `take_screenshot` capture is forwarded.
        let forwarded: [URL]
        let isWindowForward: Bool
        if let windowNumber = Self.windowNumber(arguments["window"]) {
            let windows = (context.state.values[ScreenshotState.pendingWindowsKey] as? [URL]) ?? []
            guard windowNumber >= 1, windowNumber <= windows.count else {
                return ToolOutput(
                    windows.isEmpty
                        ? "Error: no window screenshots are available. Call take_window_screenshots "
                        + "first, then delegate each window by its number."
                        : "Error: window \(windowNumber) is out of range. There are \(windows.count) "
                        + "captured windows (1 to \(windows.count))."
                )
            }
            forwarded = [windows[windowNumber - 1]]
            isWindowForward = true
        } else {
            forwarded = (context.state.values[ScreenshotState.pendingKey] as? [URL]) ?? []
            isWindowForward = false
        }

        // A subagent on a vision model runs with a prompt that asserts an image is attached; running
        // it with no capture invites a hallucinated visual answer. Fail loudly so the planner
        // captures first. (The window path above already errors when its capture is missing.)
        if forwarded.isEmpty, (subagent.model ?? model).supportsVision {
            return ToolOutput(
                "Error: the \(type) subagent needs a screenshot but none is available. Call "
                    + "take_screenshot (or take_window_screenshots then pass a window number) before "
                    + "delegating to \(type)."
            )
        }

        // Give the subagent the shared filesystem (if any) on top of its own middleware, so it can
        // read/write the same working files as the parent and its siblings — and the parent's
        // human-in-the-loop gate with it, so delegation never bypasses the user's approvals.
        var subMiddleware = subagent.middleware
        if let backend {
            subMiddleware.append(FilesystemMiddleware(backend: backend))
        }
        if let humanInTheLoop {
            subMiddleware.append(humanInTheLoop)
        }

        let agent = createAgent(
            model: subagent.model ?? model,
            tools: subagent.tools ?? baseTools,
            systemPrompt: subagent.systemPrompt,
            middleware: subMiddleware,
            maxIterations: subagent.maxIterations
        )

        // Run the subagent in isolation — only the delegated task (plus any forwarded image), no
        // parent history. Stream its visible tokens up to the parent as `.toolProgress` so the task
        // step shows the answer live and names the subagent; the first event has an empty delta just
        // to attach that label before any tokens arrive. The committed final answer is still
        // returned as this tool's result.
        let progressName = name // "task" — the tool name the timeline matches progress against
        context.onEvent(.toolProgress(name: progressName, subagent: type, delta: ""))
        // The subagent streams answer text and reasoning on separate channels; re-inline its
        // reasoning as `<think>…</think>` in the forwarded delta so the parent's delegate step still
        // shows it (the step splits inline think for display).
        let forwarder = SubagentReasoningForwarder(
            name: progressName, subagent: type, onEvent: context.onEvent
        )
        let (ok, answer) = await agent.runReturningFinalAnswer(
            [.human(task, imageURLs: forwarded)], forwarding: forwarder.forward
        )
        guard ok else {
            return ToolOutput("The \(type) subagent failed before producing a result.")
        }
        // Clear the single capture after use so the next delegation doesn't re-send a stale
        // screenshot. A per-window forward leaves the window list intact — the planner still needs
        // the other entries to analyze each window in turn.
        let cleared: AgentStateUpdate? =
            (!isWindowForward && !forwarded.isEmpty) ? .set(ScreenshotState.pendingKey, [URL]()) : nil
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolOutput(
            trimmed.isEmpty ? "The \(type) subagent finished without producing any text." : trimmed,
            stateUpdate: cleared
        )
    }
}

/// Forwards a subagent's streamed events to the parent as `.toolProgress`, re-inlining its separate
/// reasoning channel back into the delta as `<think>…</think>` so the parent's delegate step (which
/// splits inline think for display) still surfaces the subagent's reasoning. The subagent's run
/// emits events serially, so the `inThink` toggle needs no synchronization.
private final class SubagentReasoningForwarder: @unchecked Sendable {
    private let name: String
    private let subagent: String
    private let onEvent: @Sendable (AgentEvent) -> Void
    private var inThink = false

    init(name: String, subagent: String, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.name = name
        self.subagent = subagent
        self.onEvent = onEvent
    }

    @Sendable func forward(_ event: AgentEvent) {
        switch event {
        case .token(let text, _) where !text.isEmpty:
            if inThink { emit("</think>"); inThink = false }
            emit(text)
        case .reasoningToken(let text) where !text.isEmpty:
            if !inThink { emit("<think>"); inThink = true }
            emit(text)
        default:
            break
        }
    }

    private func emit(_ delta: String) {
        onEvent(.toolProgress(name: name, subagent: subagent, delta: delta))
    }
}

extension ReactAgent {
    /// Run to completion and return the committed final answer — the text streamed during the final
    /// (no-tool) round, reconstructed from the `roundCompleted` boundaries the same way the UI does.
    /// Used by `TaskTool` to compress an entire subagent run into one result for the parent.
    ///
    /// Events are buffered through an `AsyncStream` and the answer is reconstructed only after the
    /// run finishes, so nothing mutates captured state inside the `@Sendable` event callback.
    public func runReturningFinalAnswer(
        _ input: [AgentMessage], forwarding: (@Sendable (AgentEvent) -> Void)? = nil
    ) async -> (ok: Bool, answer: String) {
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        let ok = await run(input) { event in
            forwarding?(event) // live, before buffering — lets the parent stream subagent tokens
            continuation.yield(event)
        }
        continuation.finish()

        var committed = ""
        var current = ""
        for await event in stream {
            switch event {
            case .token(let text, _):
                current += text
            case .roundCompleted(let hadToolCalls):
                if hadToolCalls { current = "" } else { committed = current; current = "" }
            default:
                break
            }
        }
        return (ok, committed)
    }
}
