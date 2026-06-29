import DeepAgents
import Foundation

/// Reassembles the Anthropic Messages event stream into one canonical assistant turn. `ingest`
/// surfaces each `text_delta` as visible `.text` and each `thinking_delta` as `.reasoning`, and
/// accumulates `tool_use` blocks (the `input_json_delta` fragments concatenate into the argument
/// JSON); `finish` parses the accumulated tool calls into the canonical message.
///
/// `ingest(_:)` parses an SSE `data:` line (direct Anthropic); ``ingest(eventData:)`` takes the raw
/// event JSON so the Bedrock adapter - whose event-stream frames carry the same event objects - can
/// drive the very same decoder.
public final class AnthropicDecoder: TurnDecoder {
    public typealias RawChunk = String

    private struct Partial {
        var name: String
        var arguments = ""
    }

    private var text = ""
    private var reasoning = ""
    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []
    /// Set when the stream carries an `error` event (e.g. an `overloaded_error` mid-generation). The
    /// turn session reads it after draining the stream and throws, so a failed stream isn't mistaken
    /// for a successful (truncated) turn.
    public private(set) var streamError: String?

    public init() {}

    public func ingest(_ line: String) -> [AgentStreamChunk] {
        guard let payload = Self.ssePayload(line), let data = payload.data(using: .utf8) else { return [] }
        return ingest(eventData: data)
    }

    /// Process one decoded Messages event (the JSON after `data:`, or a Bedrock frame's inner bytes).
    public func ingest(eventData: Data) -> [AgentStreamChunk] {
        guard let event = Self.decodeEvent(eventData) else { return [] }
        switch event.type {
        case "content_block_start":
            if let block = event.contentBlock, block.type == "tool_use", let index = event.index {
                if partials[index] == nil { order.append(index) }
                partials[index] = Partial(name: block.name ?? "")
            }
            return []
        case "content_block_delta":
            return ingest(delta: event.delta, index: event.index)
        case "error":
            streamError = event.error?.message ?? event.error?.type ?? "stream error"
            return []
        default:
            return []
        }
    }

    private func ingest(delta: StreamEvent.Delta?, index: Int?) -> [AgentStreamChunk] {
        guard let delta else { return [] }
        switch delta.type {
        case "text_delta":
            guard let value = delta.text, !value.isEmpty else { return [] }
            text += value
            return [.text(value)]
        case "thinking_delta":
            guard let value = delta.thinking, !value.isEmpty else { return [] }
            reasoning += value
            return [.reasoning(value)]
        case "input_json_delta":
            if let index, let fragment = delta.partialJson { partials[index]?.arguments += fragment }
            return []
        default:
            return []
        }
    }

    public func finish() -> (stream: [AgentStreamChunk], message: AgentMessage) {
        var calls: [AgentToolCall] = []
        var malformed: [String] = []
        for index in order {
            guard let partial = partials[index], !partial.name.isEmpty else { continue }
            let trimmed = partial.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if let arguments = Self.parseArguments(trimmed) {
                calls.append(AgentToolCall(name: partial.name, arguments: arguments))
            } else {
                malformed.append("\(partial.name)(\(trimmed))")
            }
        }
        let trimmedReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([], .ai(
            text, toolCalls: calls, malformedToolCallBlocks: malformed,
            reasoning: trimmedReasoning.isEmpty ? nil : trimmedReasoning
        ))
    }

    // MARK: - Parsing helpers

    /// The payload of an SSE `data:` line (the text after `data:`, a leading space trimmed), or
    /// nil for the `event:` lines and blank separators Anthropic interleaves.
    static func ssePayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count)
        return payload.hasPrefix(" ") ? String(payload.dropFirst()) : String(payload)
    }

    static func decodeEvent(_ data: Data) -> StreamEvent? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(StreamEvent.self, from: data)
    }

    /// Parse a `tool_use` block's accumulated input JSON into the framework's argument map. Empty
    /// (a tool that takes no arguments, which streams no `input_json_delta`) is a valid `{}`.
    static func parseArguments(_ string: String) -> [String: AgentJSON]? {
        if string.isEmpty { return [:] }
        guard let data = string.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String: AgentJSON].self, from: data)
        else { return nil }
        return parsed
    }

    /// One Messages stream event (`message_start` / `content_block_*` / `message_delta` / …). Only
    /// the fields the decoder reads are modeled; snake-case keys map via `.convertFromSnakeCase`.
    struct StreamEvent: Decodable {
        let type: String
        let index: Int?
        let contentBlock: ContentBlock?
        let delta: Delta?
        let error: ErrorBody?

        struct ContentBlock: Decodable {
            let type: String
            let id: String?
            let name: String?
        }

        struct Delta: Decodable {
            let type: String?
            let text: String?
            let thinking: String?
            let partialJson: String?
            let stopReason: String?
        }

        struct ErrorBody: Decodable {
            let type: String?
            let message: String?
        }
    }
}
