import Foundation

/// Per-message context for the developer log — run facts only the agent loop knows.
/// Everything is optional so sinks degrade gracefully when a fact isn't available.
public struct AgentLogContext: Sendable {
    /// Which model drove this turn (e.g. the Hugging Face repo id).
    var modelID: String?
    /// The ReAct round (1-based) this message belongs to; `nil` for the run's input.
    var round: Int?
    /// Wall-clock seconds the model spent producing this `.ai` turn.
    var generationSeconds: Double?

    init(modelID: String? = nil, round: Int? = nil, generationSeconds: Double? = nil) {
        self.modelID = modelID
        self.round = round
        self.generationSeconds = generationSeconds
    }
}

/// A developer sink for agent messages, captured in the order they appear in a thread —
/// human turns, assistant turns (with their tool calls), and tool results. Pass one to
/// `createAgent(messageLog:)` to record a thread's full transcript for later analysis
/// (e.g. asserting tool sequences in a test, or debugging a run).
public protocol AgentMessageLog: Sendable {
    /// Record one message. Called once per message, in sequence, as the run produces it.
    func append(_ message: AgentMessage, threadId: String?, context: AgentLogContext) async
}

extension AgentMessageLog {
    /// Convenience for call sites without run context (tests, ad-hoc captures).
    public func append(_ message: AgentMessage, threadId: String?) async {
        await append(message, threadId: threadId, context: AgentLogContext())
    }
}

/// Appends each agent message as one line of JSON to a file named for the moment the log
/// was created — `YYYY-MM-DD-HH-MM-SS.jsonl` — under `directory`. One log instance ⇒ one
/// timestamped file holding that run's full message sequence (the thread id is recorded
/// on each line). An `actor` so writes serialize; failures (bad path, permissions) are
/// swallowed — logging never breaks a run.
public actor JSONLMessageLog: AgentMessageLog {
    private let fileURL: URL
    private let encoder: JSONEncoder
    /// Tool-call id → (tool name, subagent) so a later `.tool` result line can name its origin and
    /// flag `task` (subagent) delegations distinctly from ordinary tool calls.
    private var toolOrigins: [String: (name: String, subagent: String?)] = [:]

    public init(directory: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        // A short random suffix keeps two runs started within the same second (e.g. the
        // integration suite) from interleaving into one file.
        let unique = UUID().uuidString.prefix(4).lowercased()
        fileURL = directory.appendingPathComponent(
            formatter.string(from: Date()) + "-\(unique).jsonl"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func append(_ message: AgentMessage, threadId: String?, context: AgentLogContext) {
        // Remember each tool call's name + subagent so the matching result can name its origin.
        for call in message.toolCalls {
            toolOrigins[call.id.uuidString] = (call.name, Self.subagentType(of: call))
        }
        // Consume the mapping for this result (each call has exactly one result), so `toolOrigins`
        // doesn't grow unbounded across a long session.
        let origin = message.toolCallID.flatMap { toolOrigins.removeValue(forKey: $0.uuidString) }
        let entry = Entry(
            message, threadId: threadId, at: Date(), context: context,
            resultToolName: origin?.name, resultSubagent: origin?.subagent
        )
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A) // newline — one JSON object per line (JSONL)

        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// The `subagent_type` argument of a `task` call (which subagent it delegates to); `nil` for
    /// any other tool. This is the field that distinguishes a subagent delegation from a tool call.
    fileprivate static func subagentType(of call: AgentToolCall) -> String? {
        guard call.name == "task", case .string(let type)? = call.arguments["subagent_type"]
        else { return nil }
        return type
    }

    /// The JSON shape written per line. This is a richer shape than `AgentMessage` (timestamps,
    /// model id, round, separated reasoning), so flatten it into a dedicated entry here rather
    /// than encoding `AgentMessage` directly. Optional fields are omitted when nil (synthesized
    /// `encodeIfPresent`), so ordinary tool calls and non-thinking models stay as compact as before.
    private struct Entry: Encodable {
        let timestamp: Date
        let threadId: String?
        /// Which model drove this turn (Hugging Face repo id) — key for analyzing runs
        /// that mix models (deep agent planner vs. vision subagent, A/B-ing variants).
        let modelID: String?
        /// The ReAct round (1-based) this message belongs to; omitted for run input.
        let round: Int?
        /// Wall-clock seconds the model spent on this `.ai` turn.
        let generationSeconds: Double?
        let role: String
        /// The visible answer — `<think>` reasoning stripped out (for `.ai` turns).
        let content: String
        /// The model's `<think>` chain-of-thought, separated from `content` (`.ai` turns only).
        let reasoning: String?
        let toolCalls: [ToolCall]?
        /// Tool-call blocks on an `.ai` turn the parser could not read (fed back to the
        /// model as an error) — the trail to follow when debugging fumbled tool calls.
        let malformedToolCallBlocks: [String]?
        /// On a `.tool` result: which tool produced it (so results are self-describing).
        let toolName: String?
        /// On a `.tool` result: which subagent, when that tool was a `task` delegation.
        let subagentType: String?
        let toolCallID: String?
        let imageURLs: [String]?

        struct ToolCall: Encodable {
            let id: String
            let name: String
            /// Which subagent a `task` call delegates to; nil (omitted) for ordinary tools.
            let subagentType: String?
            let arguments: [String: AgentJSON]
        }

        init(
            _ message: AgentMessage, threadId: String?, at timestamp: Date,
            context: AgentLogContext, resultToolName: String?, resultSubagent: String?
        ) {
            self.timestamp = timestamp
            self.threadId = threadId
            modelID = context.modelID
            round = context.round
            // Sub-millisecond precision is noise; round to ms for legible JSONL.
            generationSeconds = context.generationSeconds.map { ($0 * 1000).rounded() / 1000 }
            role = message.role.logName

            // Record reasoning separately for assistant turns: prefer the structured reasoning
            // block, falling back to splitting inline `<think>` out of the answer (legacy turns or
            // a model that inlines it). Other roles pass their text through and carry no reasoning.
            if case .ai = message.role {
                if let blockReasoning = message.reasoning {
                    content = message.text
                    reasoning = blockReasoning
                } else {
                    let split = ThinkingSplit.split(message.text)
                    content = split.answer
                    reasoning = split.thinking
                }
            } else {
                content = message.text
                reasoning = nil
            }

            toolCalls =
                message.toolCalls.isEmpty
                    ? nil
                    : message.toolCalls.map {
                        ToolCall(
                            id: $0.id.uuidString, name: $0.name,
                            subagentType: JSONLMessageLog.subagentType(of: $0),
                            arguments: $0.arguments
                        )
                    }
            malformedToolCallBlocks =
                message.malformedToolCallBlocks.isEmpty ? nil : message.malformedToolCallBlocks
            toolName = resultToolName
            subagentType = resultSubagent
            toolCallID = message.toolCallID?.uuidString
            imageURLs =
                message.imageURLs.isEmpty ? nil : message.imageURLs.map(\.absoluteString)
        }
    }
}

/// Persisted settings (UserDefaults) for the developer message log — shared by the
/// Settings UI (which binds the toggle/path) and `MlxModelManager` (which builds the
/// logger when running the agent).
public enum AgentLogSettings {
    public static let enabledKey = "mispher.logAgentMessages"
    public static let directoryKey = "mispher.agentLogDirectory"

    /// Whether message logging is turned on.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The user-chosen directory, or a default under Application Support when unset.
    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: directoryKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultDirectory
    }

    public static var defaultDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Mispher/agent-logs", isDirectory: true)
    }

    /// A logger when enabled, else `nil` — passed to `createAgent(messageLog:)`.
    public static func makeLog() -> JSONLMessageLog? {
        isEnabled ? JSONLMessageLog(directory: directory) : nil
    }
}

extension AgentMessage.Role {
    /// Stable string for the JSONL log (`human`/`ai`/`tool`/`system`).
    fileprivate var logName: String {
        switch self {
        case .system: return "system"
        case .human: return "human"
        case .ai: return "ai"
        case .tool: return "tool"
        }
    }
}
