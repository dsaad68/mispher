import Foundation

/// The kinds of decision a human may take on an intercepted tool call — LangChain's
/// `DecisionType`.
public enum ToolDecisionType: String, Sendable, CaseIterable {
    case approve, edit, reject, respond
}

/// Per-tool human-in-the-loop policy — Mispher's port of LangChain's `InterruptOnConfig`.
/// Listing a tool in `HumanInTheLoopMiddleware.interruptOn` with one of these gates every
/// call to it behind the user's decision.
public struct InterruptOnConfig: Sendable, Equatable {
    /// The decisions the user may take for this tool. Defaults to the pair Mispher's
    /// approval card offers.
    var allowedDecisions: [ToolDecisionType]
    /// Optional fixed description shown to the user instead of the generated
    /// "prefix + tool + args" one.
    var description: String?

    public init(allowedDecisions: [ToolDecisionType] = [.approve, .reject], description: String? = nil) {
        self.allowedDecisions = allowedDecisions
        self.description = description
    }
}

/// One tool call awaiting the user's review — LangChain's `ActionRequest` plus its
/// `ReviewConfig`, flattened into what an approval UI needs.
public struct ToolApprovalRequest: Sendable, Identifiable {
    /// The underlying `AgentToolCall.id`, so UI state keys to the exact call.
    public let id: UUID
    public let toolName: String
    public let arguments: [String: AgentJSON]
    /// What the user is being asked, e.g. "Tool execution requires approval\n\nTool: …".
    public let description: String
    public let allowedDecisions: [ToolDecisionType]

    public init(
        id: UUID, toolName: String, arguments: [String: AgentJSON],
        description: String, allowedDecisions: [ToolDecisionType]
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.description = description
        self.allowedDecisions = allowedDecisions
    }

    /// One argument rendered for display in the approval UI.
    public struct ArgumentRow: Sendable, Identifiable {
        public let key: String
        public let value: String

        public var id: String { key }
    }

    /// Per-argument display rows for the approval UI, key-sorted like
    /// `AgentToolCall.describedArguments`.
    public var argumentRows: [ArgumentRow] {
        arguments
            .sorted { $0.key < $1.key }
            .map { ArgumentRow(key: $0.key, value: AgentToolCall.describe($0.value)) }
    }
}

/// The human's verdict on one intercepted call — LangChain's `ApproveDecision` /
/// `EditDecision` / `RejectDecision` / `RespondDecision`.
public enum ToolApprovalDecision: Sendable {
    /// Run the call as the model issued it.
    case approve
    /// Run the call with these arguments instead (same tool, same call id).
    case edit(arguments: [String: AgentJSON])
    /// Don't run the call; feed an error back so the model adjusts (optionally why).
    case reject(message: String?)
    /// Don't run the call; feed `message` back as if it were the tool's (successful) result.
    case respond(message: String)

    public var type: ToolDecisionType {
        switch self {
        case .approve: return .approve
        case .edit: return .edit
        case .reject: return .reject
        case .respond: return .respond
        }
    }
}

/// Presents one request to the human and returns their decision. The UI side typically
/// publishes the request, suspends on a continuation, and resumes it from the approve /
/// deny buttons — the agent run waits inside this call.
public typealias ToolApprovalHandler = @Sendable (ToolApprovalRequest) async -> ToolApprovalDecision

/// The handler returned a decision the tool's config doesn't allow — LangChain raises
/// `ValueError` here; we surface it as a failed tool call the model can see.
public struct HumanInTheLoopError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

/// Human-in-the-loop middleware — Mispher's port of LangChain's `HumanInTheLoopMiddleware`.
/// Tools named in `interruptOn` only run after the user approves them; the user may also
/// edit the call's arguments, reject it (the model gets an error and moves on), or answer
/// in the tool's place.
///
/// LangChain implements this in `after_model` with a LangGraph `interrupt`, because its
/// runs are checkpointed and resumed across processes. Mispher's loop is in-process, so the
/// natural seam is `wrapToolCall`: the call suspends on `approvalHandler` until the user
/// decides, then proceeds, proceeds-with-edits, or short-circuits — per call, in dispatch
/// order, which matches LangChain's per-call decisions. Tools not listed in `interruptOn`
/// are auto-approved untouched.
public struct HumanInTheLoopMiddleware: AgentMiddleware {
    public let interruptOn: [String: InterruptOnConfig]
    /// Prepended to generated request descriptions — LangChain's `description_prefix`.
    let descriptionPrefix: String
    let approvalHandler: ToolApprovalHandler

    init(
        interruptOn: [String: InterruptOnConfig],
        descriptionPrefix: String = "Tool execution requires approval",
        approvalHandler: @escaping ToolApprovalHandler
    ) {
        self.interruptOn = interruptOn
        self.descriptionPrefix = descriptionPrefix
        self.approvalHandler = approvalHandler
    }

    public var name: String { "human_in_the_loop" }

    /// Tell the model up front that some tools are gated, so a rejection reads as the
    /// user's decision rather than a tool malfunction it should retry.
    public func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        guard !interruptOn.isEmpty else { return try await handler(request) }
        let composed = [request.systemPrompt, systemPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return try await handler(request.override(systemPrompt: composed))
    }

    var systemPrompt: String {
        let gated = interruptOn.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")
        return """
        ## Tool approvals
        These tool calls run only after the user approves them in the app: \(gated). Calling \
        them is fine - the user is asked automatically. If a call comes back rejected, that \
        was the user's decision: do not retry it with the same arguments; adjust your \
        approach or continue without it.
        """
    }

    public func wrapToolCall(
        _ request: ToolCallRequest,
        _ handler: (ToolCallRequest) async throws -> AgentMessage
    ) async throws -> AgentMessage {
        guard let config = interruptOn[request.call.name] else { return try await handler(request) }
        let call = request.call
        let approval = ToolApprovalRequest(
            id: call.id,
            toolName: call.name,
            arguments: call.arguments,
            description: config.description
                ?? "\(descriptionPrefix)\n\nTool: \(call.name)\nArgs: \(call.describedArguments)",
            allowedDecisions: config.allowedDecisions
        )

        let decision = await approvalHandler(approval)
        guard config.allowedDecisions.contains(decision.type) else {
            throw HumanInTheLoopError(
                "Unexpected human decision \"\(decision.type.rawValue)\" for tool \"\(call.name)\": "
                    + "allowed decisions are "
                    + config.allowedDecisions.map(\.rawValue).joined(separator: ", ") + "."
            )
        }

        switch decision {
        case .approve:
            return try await handler(request)
        case .edit(let arguments):
            var edited = request
            edited.call = AgentToolCall(id: call.id, name: call.name, arguments: arguments)
            return try await handler(edited)
        case .reject(let message):
            return .tool(Self.rejectionFeedback(call.name, message: message), toolCallID: call.id)
        case .respond(let message):
            return .tool(message, toolCallID: call.id)
        }
    }

    /// The `tool`-role error fed back for a rejected call, in the same `{"error": …}` shape
    /// as the loop's other failure feedback (LangChain marks its rejection `ToolMessage`
    /// with `status="error"`).
    static func rejectionFeedback(_ toolName: String, message: String?) -> String {
        let reason = message.flatMap { $0.isEmpty ? nil : " Reason: \($0)" } ?? ""
        return ReactAgent.errorJSON(
            "The user rejected the \(toolName) tool call.\(reason) Do not retry it with the "
                + "same arguments - adjust your approach or continue without it."
        )
    }
}
