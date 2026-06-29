import Foundation

/// A compiled agent — Mispher's port of the object returned by LangChain's
/// `create_agent`. It wires middleware, tools, short-term memory, and an underlying
/// `ChatModel` into a ReAct run. Build one with `createAgent(...)`.
///
/// `ReactAgent` owns the ReAct loop: it asks the `ChatModel` for one run-scoped
/// `ModelTurnSession`, then drives it one turn per round — running middleware hooks
/// around each model call, dispatching the tool calls the model emits, and feeding the
/// results back as the next round's input. This mirrors LangChain's graph (`model` ⇄
/// `tools`, looping) and keeps the structured exchange in `AgentState.messages`.
///
/// Each round the model node rebuilds its prompt from `state.messages` against a fresh KV
/// cache (see `RebuildTurnSession`), so middleware may rewrite the conversation between
/// rounds — `ScreenshotMiddleware`, for one, splices a captured image into history for the
/// next round. `wrapModelCall` must still not invoke its handler more than once per round.
public struct ReactAgent: Sendable {
    let model: any ChatModel
    /// The planner's context window in tokens, when the model reports one — for a host's context-usage
    /// meter (the same window summarization's 85% trigger measures against). `nil` when unknown.
    public var contextWindowTokens: Int? { model.contextWindowTokens }
    public let tools: [any AgentTool]
    let systemPrompt: String?
    public let middleware: [any AgentMiddleware]
    let memory: (any AgentCheckpointer)?
    /// Hard cap on model rounds, so a model that loops tool calls forever still
    /// terminates — LangChain's `recursion_limit`. On hitting it the loop runs one final
    /// tool-less turn (see `forceFinalAnswer`) rather than raising.
    let maxIterations: Int
    /// Optional developer sink: every message this run produces is appended to it, in
    /// order (human input, assistant turns with tool calls, tool results).
    let messageLog: (any AgentMessageLog)?

    /// Run the agent over `input` (typically a single human message). Prior turns for
    /// `threadId` are loaded from `memory` (short-term memory) and the updated
    /// conversation is saved back. Progress streams via `onEvent`, in order.
    /// - Returns: `true` on success, `false` if the run failed.
    @discardableResult
    public func run(
        _ input: [AgentMessage],
        threadId: String? = nil,
        onEvent: @Sendable @escaping (AgentEvent) -> Void
    ) async -> Bool {
        do {
            let prior = await loadHistory(threadId)
            var state = AgentState(messages: prior + input)
            // Seed the values summarization reads from state: the thread id (for its archive) and the
            // fixed prompt overhead (system prompt + tool schemas), so its 85% trigger measures the
            // real request size, not just the conversation.
            seedSummarizationState(&state, threadId: threadId)

            // Log this turn's new input (prior history was logged on earlier runs).
            for message in input { await log(message, threadId: threadId, round: nil) }

            for middleware in middleware { await middleware.beforeAgent(&state) }

            // One run-scoped, stateless model node; this loop owns the iteration and hands
            // it the full conversation each round.
            let session = model.makeSession()
            var round = 0
            // Duplicate-round guard: small models can re-issue the identical tool call(s)
            // round after round (the convergence bug's signature). Track the previous
            // round's call set; after `maxRepeatedRounds` consecutive repeats, stop
            // dispatching and force a final answer instead of burning the iteration cap.
            var previousSignature: [String]?
            var repeatedRounds = 0

            agentLoop: while true {
                round += 1
                if round > maxIterations {
                    try await forceFinalAnswer(
                        session: session, state: &state, round: round,
                        threadId: threadId, onEvent: onEvent
                    )
                    break agentLoop
                }

                await runBeforeModel(&state, onEvent: onEvent)

                let handler = composedModelHandler(session: session, onEvent: onEvent)
                let request = ModelRequest(
                    messages: state.messages, systemPrompt: systemPrompt, tools: tools
                )
                let modelStarted = Date()
                let response = try await handler(request)
                state.messages.append(response.message)
                await recordModelTurn(response.message, round: round, threadId: threadId, started: modelStarted)

                for middleware in middleware.reversed() { await middleware.afterModel(&state) }

                // Honor a middleware `jump_to` before deciding what to do next.
                switch state.jumpTo {
                case .end: state.jumpTo = nil; break agentLoop
                case .model: state.jumpTo = nil; continue agentLoop
                case .tools, .none: state.jumpTo = nil
                }

                let calls = response.message.toolCalls
                let malformed = response.message.malformedToolCallBlocks
                onEvent(.roundCompleted(hadToolCalls: !calls.isEmpty || !malformed.isEmpty))
                if calls.isEmpty, malformed.isEmpty { break agentLoop }

                // A round whose only tool calls were unparseable is not a final answer:
                // feed the error back so the model can re-emit the call or answer in text.
                if calls.isEmpty {
                    await appendMalformedFeedback(malformed, state: &state, round: round, threadId: threadId)
                    continue agentLoop
                }

                // Duplicate-round guard: a call set identical to the previous round's
                // can't produce new information — anything legitimately re-run (a file
                // re-read after an edit, a fresh screenshot after a delegation) has a
                // different call in between, so it is never consecutive-identical. The
                // first repeat is not re-executed: the model gets a redirect to the
                // result it already has. If it repeats again, force the final answer.
                let signature = calls.map(\.signature).sorted()
                if signature == previousSignature {
                    repeatedRounds += 1
                } else {
                    repeatedRounds = 0
                    previousSignature = signature
                }
                if repeatedRounds >= Self.maxRepeatedRounds {
                    try await forceFinalAnswer(
                        session: session, state: &state, round: round,
                        threadId: threadId, onEvent: onEvent
                    )
                    break agentLoop
                }
                if repeatedRounds > 0 {
                    await appendDuplicateFeedback(
                        calls, state: &state, round: round, threadId: threadId, onEvent: onEvent
                    )
                    continue agentLoop
                }

                await dispatchRound(
                    response.message, state: &state, round: round,
                    threadId: threadId, onEvent: onEvent
                )
            }

            for middleware in middleware.reversed() { await middleware.afterAgent(&state) }

            await saveHistory(threadId, messages: state.messages)
            onEvent(.completed)
            return true
        } catch {
            onEvent(.failed(Self.describe(error)))
            return false
        }
    }

    /// The per-round model handler: the session turn wrapped in every middleware's
    /// `wrapModelCall`, first-registered middleware outermost. The innermost handler runs
    /// one model turn over the request's messages (honoring middleware history rewrites),
    /// streams visible text via `onEvent(.token(...))`, and returns the assistant message
    /// (text + any tool calls). It does NOT run tools.
    private func composedModelHandler(
        session: any ModelTurnSession,
        onEvent: @Sendable @escaping (AgentEvent) -> Void
    ) -> (ModelRequest) async throws -> ModelResponse {
        let base: (ModelRequest) async throws -> ModelResponse = { request in
            let message = try await session.nextTurn(
                messages: request.messages,
                systemPrompt: request.systemPrompt,
                tools: request.tools,
                onChunk: Self.streamHandler(onEvent)
            )
            return ModelResponse(message: message)
        }
        var handler = base
        for middleware in middleware.reversed() {
            let next = handler
            handler = { request in try await middleware.wrapModelCall(request, next) }
        }
        return handler
    }

    /// Seed the `state.values` entries ``SummarizationMiddleware`` reads: the thread id (so it can
    /// address the archive) and the fixed prompt overhead text (system prompt + tool schemas), so its
    /// trigger counts the whole request, not just the messages. The overhead is only computed when a
    /// summarizer is actually registered.
    private func seedSummarizationState(_ state: inout AgentState, threadId: String?) {
        if let threadId { state.values[SummarizationMiddleware.threadIdStateKey] = threadId }
        guard middleware.contains(where: { $0 is SummarizationMiddleware }) else { return }
        let overhead = SummarizationMiddleware.promptOverheadText(systemPrompt: systemPrompt, tools: tools)
        if !overhead.isEmpty { state.values[SummarizationMiddleware.promptOverheadStateKey] = overhead }
    }

    /// Run every middleware's `beforeModel` hook, then emit a `.contextCompacted` event if one of
    /// them (summarization) rewrote the history this round — it leaves the outcome in `state.values`,
    /// mirroring how a tool's `todos` update becomes `.todosUpdated`.
    private func runBeforeModel(
        _ state: inout AgentState, onEvent: @Sendable (AgentEvent) -> Void
    ) async {
        for middleware in middleware { await middleware.beforeModel(&state) }
        guard let outcome = state.values[SummarizationMiddleware.outcomeStateKey] as? CompactionOutcome
        else { return }
        onEvent(.contextCompacted(tokensBefore: outcome.tokensBefore, tokensAfter: outcome.tokensAfter))
        state.values[SummarizationMiddleware.outcomeStateKey] = nil
    }

    /// Append the model's turn to the developer log with its generation time. Split out so the loop
    /// body stays within length.
    private func recordModelTurn(
        _ message: AgentMessage, round: Int, threadId: String?, started: Date
    ) async {
        await messageLog?.append(
            message, threadId: threadId,
            context: AgentLogContext(
                modelID: model.modelID, round: round,
                generationSeconds: Date().timeIntervalSince(started)
            )
        )
    }

    /// Map a session's streamed pieces onto agent events: visible answer `text` to `.token`,
    /// chain-of-thought `reasoning` to `.reasoningToken` (its own channel for the UI's disclosure).
    private static func streamHandler(
        _ onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) -> @Sendable (AgentStreamChunk) -> Void {
        { chunk in
            switch chunk {
            case .text(let text): onEvent(.token(text, isFinal: false))
            case .reasoning(let reasoning): onEvent(.reasoningToken(reasoning))
            }
        }
    }

    /// Dispatch one round's tool calls (from the model's message), appending every result
    /// to the conversation so the model (next round) and any later tool this round see the
    /// full exchange; also feeds back the round's malformed blocks (if any) and surfaces
    /// todo-list updates.
    private func dispatchRound(
        _ message: AgentMessage,
        state: inout AgentState,
        round: Int,
        threadId: String?,
        onEvent: @Sendable @escaping (AgentEvent) -> Void
    ) async {
        var todosTouched = false
        for call in message.toolCalls {
            let (result, update) = await dispatchTool(
                call, tools: tools, state: state, onEvent: onEvent
            )
            merge(update, into: &state.values)
            if update?.values["todos"] != nil { todosTouched = true }
            state.messages.append(result)
            await log(result, threadId: threadId, round: round)
        }
        if !message.malformedToolCallBlocks.isEmpty {
            await appendMalformedFeedback(
                message.malformedToolCallBlocks, state: &state, round: round, threadId: threadId
            )
        }
        if todosTouched, let todos = state.values["todos"] as? [TodoItem] {
            onEvent(.todosUpdated(todos))
        }
    }

    /// Feed back a redirect instead of re-executing a consecutive-duplicate call set:
    /// the result is already in the conversation, so re-running burns seconds for
    /// nothing (observed on-device: `read_clipboard` re-run for an identical result at
    /// ~7s a round). Each duplicate call still gets a `tool`-role response — the trained
    /// chat format pairs every emitted call with a result, so skipping silently would be
    /// off-distribution.
    private func appendDuplicateFeedback(
        _ calls: [AgentToolCall],
        state: inout AgentState,
        round: Int,
        threadId: String?,
        onEvent: @Sendable @escaping (AgentEvent) -> Void
    ) async {
        for call in calls {
            let text = Self.errorJSON(
                "You already called \(call.name) with the same arguments - its result is "
                    + "in the conversation above. Use that result, call a different tool, "
                    + "or answer the user now."
            )
            onEvent(.toolFailed(name: call.name, error: text))
            let message = AgentMessage.tool(text, toolCallID: call.id)
            state.messages.append(message)
            await log(message, threadId: threadId, round: round)
        }
    }

    /// Append the parse-error feedback for this round's unparseable tool-call blocks.
    private func appendMalformedFeedback(
        _ blocks: [String], state: inout AgentState, round: Int, threadId: String?
    ) async {
        let feedback = AgentMessage.tool(Self.malformedFeedback(blocks))
        state.messages.append(feedback)
        await log(feedback, threadId: threadId, round: round)
    }

    /// Append to the developer message log. `modelID` records which model *drove* the
    /// turn, so it's attached only to `.ai` messages — human input and tool results
    /// aren't model-generated and would otherwise carry a misleading model id.
    private func log(_ message: AgentMessage, threadId: String?, round: Int?) async {
        await messageLog?.append(
            message, threadId: threadId,
            context: AgentLogContext(modelID: message.role == .ai ? model.modelID : nil, round: round)
        )
    }

    /// Consecutive identical-call-set rounds tolerated before the loop gives up and
    /// forces a final answer. A repeated round is never re-executed (see
    /// `appendDuplicateFeedback`) — this cap ends the run when the model won't move on
    /// even after being redirected to the result it already has.
    static let maxRepeatedRounds = 2

    /// Longest tool result (in characters) fed back to the model. LFM models have a 32k
    /// context; one oversized `read_file`/`task` result can crowd out the conversation,
    /// so anything longer is cut with a note saying how much was dropped.
    static let maxToolResultCharacters = 6000

    /// One last model turn with NO tools declared (so the chat template omits the tool
    /// list entirely — the strongest "answer now" signal) plus an explicit instruction to
    /// answer in text. Used when the loop is cut short (iteration cap, duplicate-round
    /// guard) so the user still gets an answer instead of a dangling tool result. Calls
    /// the session directly: middleware `wrapModelCall` guidance describes tools that are
    /// deliberately absent here. Any tool calls the model still emits are dropped.
    private func forceFinalAnswer(
        session: any ModelTurnSession,
        state: inout AgentState,
        round: Int,
        threadId: String?,
        onEvent: @Sendable @escaping (AgentEvent) -> Void
    ) async throws {
        let nudge = """
        Tool calling is now disabled. Using the conversation above, give the user your \
        final answer in plain text. Do not call any tools.
        """
        let prompt = [systemPrompt, nudge].compactMap { $0 }.joined(separator: "\n\n")
        let started = Date()
        let message = try await session.nextTurn(
            messages: state.messages, systemPrompt: prompt, tools: [],
            onChunk: Self.streamHandler(onEvent)
        )
        let final = AgentMessage.ai(message.text)
        state.messages.append(final)
        await messageLog?.append(
            final, threadId: threadId,
            context: AgentLogContext(
                modelID: model.modelID, round: round,
                generationSeconds: Date().timeIntervalSince(started)
            )
        )
        onEvent(.roundCompleted(hadToolCalls: false))
    }

    /// The `tool`-role error fed back when the model emitted tool-call blocks that could
    /// not be parsed, so it can re-emit them correctly (or answer in text) next round.
    static func malformedFeedback(_ blocks: [String]) -> String {
        let shown = blocks.map { block in
            block.count > 200 ? String(block.prefix(200)) + "…" : block
        }.joined(separator: "\n")
        return errorJSON(
            "Your tool call could not be parsed: \(shown). Re-emit it as "
                + "[tool_name(argument=\"value\")] with every string argument quoted, "
                + "or answer in plain text if you are done."
        )
    }

    /// Check a parsed call against the tool's declared parameters; nil when acceptable,
    /// else a correction message for the model. Deliberately conservative — only the
    /// unambiguous violations (missing required parameter, value outside a declared
    /// `enum`) are rejected, because tools like `write_todos` accept looser shapes than
    /// their schema advertises and coerce them in `execute`.
    static func schemaViolation(_ call: AgentToolCall, tool: any AgentTool) -> String? {
        var problems: [String] = []
        for parameter in tool.parameters {
            let value = call.arguments[parameter.name]
            if parameter.isRequired, value == nil {
                problems.append("missing required parameter `\(parameter.name)`")
            }
            // An empty enum (e.g. the `task` tool with no subagents registered) would
            // reject everything with a blank allowed-list — let the tool itself produce
            // its richer error instead.
            if let allowed = parameter.extraProperties["enum"] as? [String], !allowed.isEmpty,
               case .string(let raw)? = value, !allowed.contains(raw) {
                problems.append(
                    "`\(parameter.name)` must be one of: "
                        + allowed.joined(separator: ", ") + " (got \"\(raw)\")"
                )
            }
        }
        guard !problems.isEmpty else { return nil }
        return "Invalid call to '\(call.name)': " + problems.joined(separator: "; ")
            + ". Fix the arguments and call it again."
    }

    /// Render an error as the JSON object shape (`{"error": "…"}`) LFM tool-use examples
    /// feed back, with proper escaping.
    static func errorJSON(_ text: String) -> String {
        let object = ["error": text]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else { return "{\"error\": \"unencodable error\"}" }
        return json
    }

    /// Cut an oversized tool result down to `maxToolResultCharacters`, noting the cut so
    /// the model knows it saw a prefix rather than the whole thing.
    static func truncatedToolResult(_ content: String) -> String {
        guard content.count > maxToolResultCharacters else { return content }
        return String(content.prefix(maxToolResultCharacters))
            + "\n[Result truncated: showing the first \(maxToolResultCharacters) of "
            + "\(content.count) characters.]"
    }

    // MARK: - Tool dispatch

    /// Execute one tool call through the `wrapToolCall` middleware chain. Returns the
    /// `.tool` result message (tagged with the originating call's id) plus any state
    /// update the tool produced. Errors are caught and returned as text so the model can
    /// recover rather than aborting.
    private func dispatchTool(
        _ call: AgentToolCall,
        tools: [any AgentTool],
        state: AgentState,
        onEvent: @Sendable @escaping (AgentEvent) -> Void
    ) async -> (message: AgentMessage, stateUpdate: AgentStateUpdate?) {
        onEvent(.toolStarted(name: call.name, input: call.describedArguments))

        guard let tool = tools.first(where: { $0.name == call.name }) else {
            let names = tools.map(\.name).joined(separator: ", ")
            let text = Self.errorJSON("Unknown tool '\(call.name)'. Available tools: \(names).")
            onEvent(.toolFailed(name: call.name, error: text))
            return (.tool(text, toolCallID: call.id), nil)
        }

        // Validate the call against the tool's declared schema before executing — the
        // on-device stand-in for Outlines-style schema enforcement (mlx-swift has no
        // constrained decoding). A violation is fed back as an error so the model can fix
        // the arguments next round instead of the tool failing in a less legible way.
        if let violation = Self.schemaViolation(call, tool: tool) {
            let text = Self.errorJSON(violation)
            onEvent(.toolFailed(name: call.name, error: text))
            return (.tool(text, toolCallID: call.id), nil)
        }

        let context = ToolContext(state: state, onEvent: onEvent)
        let captured = CapturedUpdate()

        let base: (ToolCallRequest) async throws -> AgentMessage = { request in
            let output = try await tool.execute(request.call.arguments, context)
            captured.value = output.stateUpdate
            return .tool(output.content, toolCallID: call.id)
        }

        var handler = base
        for middleware in middleware.reversed() {
            let next = handler
            handler = { request in try await middleware.wrapToolCall(request, next) }
        }

        do {
            var message = try await handler(ToolCallRequest(call: call, state: state))
            message.content = [.text(Self.truncatedToolResult(message.text))]
            // A tool can attach an image (e.g. the screenshot tool) or a line diff (edit_file)
            // via its state update; surface them on the completion event so the UI can show a
            // thumbnail / a diff card.
            let imageURL = (captured.value?.values[ScreenshotState.pendingKey] as? [URL])?.first
            let editDiff = captured.value?.values[EditDiffState.pendingKey] as? FileDiff
            onEvent(.toolCompleted(name: call.name, result: message.text, imageURL: imageURL, editDiff: editDiff))
            return (message, captured.value)
        } catch {
            let text = Self.errorJSON(Self.describe(error))
            onEvent(.toolFailed(name: call.name, error: text))
            return (.tool(text, toolCallID: call.id), nil)
        }
    }

    /// Merge a tool's state update into the agent state — LangChain's `Command(update=…)`
    /// for non-message keys (later writes overwrite earlier ones).
    private func merge(_ update: AgentStateUpdate?, into values: inout [String: any Sendable]) {
        guard let update else { return }
        for (key, value) in update.values { values[key] = value }
    }

    // MARK: - Compaction

    /// Force a summarization pass on a thread's stored history, outside a run — the manual `/compact`
    /// (Ripple) and the Compact action (Mispher app). Loads the thread from `memory`, runs the
    /// ``SummarizationMiddleware`` (if one is registered) with `force: true`, saves the rewritten
    /// `[summary] + tail` back, and returns the outcome. Returns `nil` when there is no summarization
    /// middleware, no memory, or nothing safe to compact.
    @discardableResult
    public func compact(threadId: String?) async -> CompactionOutcome? {
        guard let summarizer = middleware.lazy.compactMap({ $0 as? SummarizationMiddleware }).first,
              threadId != nil
        else { return nil }
        var messages = await loadHistory(threadId)
        // Match the automatic path: count the fixed prompt overhead (system prompt + tool schemas) so
        // the reported before/after sizes reflect the real request, not just the conversation.
        let overheadText = SummarizationMiddleware.promptOverheadText(systemPrompt: systemPrompt, tools: tools)
        let overhead = summarizer.tokenCounter.count(overheadText)
        guard let outcome = await summarizer.compact(
            &messages, threadId: threadId, force: true, overheadTokens: overhead
        ) else { return nil }
        await saveHistory(threadId, messages: messages)
        return outcome
    }

    // MARK: - Memory

    private func loadHistory(_ threadId: String?) async -> [AgentMessage] {
        guard let threadId, let memory else { return [] }
        return await memory.load(threadId)
    }

    private func saveHistory(_ threadId: String?, messages: [AgentMessage]) async {
        guard let threadId, let memory else { return }
        // Persist the full structured conversation — human, assistant (with tool calls),
        // and tool results — so a resumed thread retains what the agent looked up. (A new
        // session only re-templates the text turns into a cold cache; see `MlxTurnSession`.)
        await memory.save(threadId, messages)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// A tiny reference box so `dispatchTool`'s inner handler can hand the tool's state
/// update back out of the `wrapToolCall` chain (which only carries the `AgentMessage`).
private final class CapturedUpdate {
    var value: AgentStateUpdate?
}

private extension AgentToolCall {
    /// A deterministic identity for the duplicate-round guard: name plus the key-sorted
    /// argument rendering. Two calls with the same name and arguments compare equal.
    var signature: String { "\(name)(\(describedArguments))" }
}
