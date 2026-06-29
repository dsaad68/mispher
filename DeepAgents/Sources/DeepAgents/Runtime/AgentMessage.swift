import Foundation

/// One message in an agent conversation — Mispher's idiomatic mirror of LangChain's
/// message model (`SystemMessage` / `HumanMessage` / `AIMessage` / `ToolMessage`).
/// Inference-agnostic: an adapter (e.g. `DeepAgentsMLX`) bridges it to a backend's prompt
/// message type for templating.
///
/// Images are stored as `URL`s so the value stays `Sendable`; an adapter resolves them to
/// its own image type only when the prompt is built, off the main actor.
public struct AgentMessage: Sendable, Identifiable {
    public enum Role: String, Sendable, Codable { case system, human, ai, tool }

    public let id: UUID
    public var role: Role
    /// The message body as typed parts (text / reasoning / image) — LangChain's content blocks.
    /// Read the convenience accessors (`text`, `reasoning`, `images`) rather than the raw list.
    public var content: [AgentContentBlock]
    /// Tool calls the model requested on an `.ai` turn.
    public var toolCalls: [AgentToolCall]
    /// Tool-call blocks the model emitted on an `.ai` turn that could NOT be parsed
    /// (the raw text between `<|tool_call_start|>`/`<|tool_call_end|>`). The ReAct loop
    /// feeds these back as an error so the model can re-emit the call instead of the
    /// run silently ending as if it were a final answer.
    public var malformedToolCallBlocks: [String]
    /// On a `.tool` turn, the `id` of the `AgentToolCall` this result answers —
    /// LangChain's `ToolMessage.tool_call_id`. `nil` for non-tool turns. App-side
    /// linkage only (the MLX `Chat.Message` bridge has no id slot to carry it).
    public var toolCallID: UUID?
    /// Provenance for synthesized turns — the analogue of LangChain's
    /// `additional_kwargs["lc_source"]`. ``summarizationSource`` tags the rolling-summary
    /// turn (and its acknowledgment) so a later compaction folds them rather than treating
    /// them as originals, and a host can render them as "Summary". `nil` for normal turns.
    public var source: String?

    /// Marker value for ``source`` on the summary turn (and its ack) a compaction inserts.
    public static let summarizationSource = "summarization"

    /// Whether this is a compaction-synthesized turn (summary or its acknowledgment).
    public var isSummary: Bool { source == Self.summarizationSource }

    public init(
        id: UUID = UUID(), role: Role, content: [AgentContentBlock],
        toolCalls: [AgentToolCall] = [],
        malformedToolCallBlocks: [String] = [], toolCallID: UUID? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.malformedToolCallBlocks = malformedToolCallBlocks
        self.toolCallID = toolCallID
        self.source = source
    }

    // MARK: - Content accessors

    /// The visible answer text — every `.text` block joined (reasoning and images excluded).
    public var text: String {
        content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined()
    }

    /// The chain-of-thought, if any — every `.reasoning` block joined, else nil.
    public var reasoning: String? {
        let parts = content.compactMap { if case .reasoning(let value) = $0 { value } else { nil } }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The image parts, in order.
    public var images: [AgentImage] {
        content.compactMap { if case .image(let value) = $0 { value } else { nil } }
    }

    /// The URLs of any image parts that carry one (VLMs only); ignored for text models. A
    /// compatibility view over `images` for call sites that only handle URL-backed images.
    public var imageURLs: [URL] { images.compactMap(\.url) }

    // MARK: - Factories

    public static func system(_ content: String) -> AgentMessage {
        .init(role: .system, content: [.text(content)])
    }

    public static func human(_ content: String, imageURLs: [URL] = []) -> AgentMessage {
        .init(role: .human, content: [.text(content)] + imageURLs.map { .image(AgentImage(url: $0)) })
    }

    /// A human turn whose images may be URL-backed, inline base64, or a provider file id.
    public static func human(_ content: String, images: [AgentImage]) -> AgentMessage {
        .init(role: .human, content: [.text(content)] + images.map { .image($0) })
    }

    public static func ai(
        _ content: String, toolCalls: [AgentToolCall] = [],
        malformedToolCallBlocks: [String] = [], reasoning: String? = nil
    ) -> AgentMessage {
        var blocks: [AgentContentBlock] = []
        if let reasoning, !reasoning.isEmpty { blocks.append(.reasoning(reasoning)) }
        blocks.append(.text(content))
        return .init(
            role: .ai, content: blocks, toolCalls: toolCalls,
            malformedToolCallBlocks: malformedToolCallBlocks
        )
    }

    public static func tool(_ content: String, toolCallID: UUID? = nil) -> AgentMessage {
        .init(role: .tool, content: [.text(content)], toolCallID: toolCallID)
    }
}

extension AgentMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, role, content, toolCalls, malformedToolCallBlocks, toolCallID, imageURLs, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(Role.self, forKey: .role)
        toolCalls = try container.decodeIfPresent([AgentToolCall].self, forKey: .toolCalls) ?? []
        malformedToolCallBlocks =
            try container.decodeIfPresent([String].self, forKey: .malformedToolCallBlocks) ?? []
        toolCallID = try container.decodeIfPresent(UUID.self, forKey: .toolCallID)
        source = try container.decodeIfPresent(String.self, forKey: .source)

        // New shape: `content` is the block list. Legacy shape: `content` is a plain string (plus a
        // sibling `imageURLs`), and an `.ai` string may carry inline `<think>` to recover as reasoning.
        if let blocks = try? container.decode([AgentContentBlock].self, forKey: .content) {
            content = blocks
        } else {
            let legacy = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            var blocks: [AgentContentBlock] = []
            if role == .ai {
                let split = ThinkingSplit.split(legacy)
                if let thinking = split.thinking { blocks.append(.reasoning(thinking)) }
                blocks.append(.text(split.answer))
            } else {
                blocks.append(.text(legacy))
            }
            if let urls = try container.decodeIfPresent([URL].self, forKey: .imageURLs) {
                blocks += urls.map { .image(AgentImage(url: $0)) }
            }
            content = blocks
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        if !toolCalls.isEmpty { try container.encode(toolCalls, forKey: .toolCalls) }
        if !malformedToolCallBlocks.isEmpty {
            try container.encode(malformedToolCallBlocks, forKey: .malformedToolCallBlocks)
        }
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(source, forKey: .source)
    }
}

/// A tool call the model requested — the framework's backend-neutral tool-call value.
public struct AgentToolCall: Sendable, Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let arguments: [String: AgentJSON]

    public init(id: UUID = UUID(), name: String, arguments: [String: AgentJSON]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// A compact, human-readable rendering of the arguments, for UI display
    /// (e.g. `text: hello, count: 2`). Empty when the tool takes no arguments.
    public var describedArguments: String {
        guard !arguments.isEmpty else { return "" }
        return arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \(Self.describe($0.value))" }
            .joined(separator: ", ")
    }

    /// One JSON argument value rendered for humans — shared with the tool-approval UI.
    public static func describe(_ value: AgentJSON) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return String(b)
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array(let items): return "[" + items.map { describe($0) }.joined(separator: ", ") + "]"
        case .object(let object):
            // Key-sorted so the rendering is deterministic for nested objects too — the
            // duplicate-round guard relies on this to recognize identical repeated calls.
            return "{" + object.sorted { $0.key < $1.key }
                .map { "\($0.key): \(describe($0.value))" }.joined(separator: ", ") + "}"
        }
    }
}
