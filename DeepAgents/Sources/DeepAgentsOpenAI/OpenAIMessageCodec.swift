import DeepAgents
import Foundation

/// The OpenAI-compatible message codec: encodes the canonical ``AgentMessage`` history into a
/// chat-completions request body, and decodes the streamed Server-Sent-Events back into a canonical
/// assistant turn. All OpenAI wire quirks (the `tool_calls` JSON shape, `image_url` content parts,
/// SSE delta reassembly) live here; ``OpenAITurnSession`` keeps only the HTTP transport.
public struct OpenAIMessageCodec: MessageCodec {
    let model: String
    let parameters: OpenAIGenerateParameters
    /// When true, ask the endpoint to return chain-of-thought (OpenRouter's `reasoning` param). The
    /// decoder reads `reasoning` / `reasoning_content` regardless, so providers that return it
    /// unprompted (e.g. DeepSeek) still surface reasoning without this set.
    let reasoning: Bool

    public init(model: String, parameters: OpenAIGenerateParameters, reasoning: Bool = false) {
        self.model = model
        self.parameters = parameters
        self.reasoning = reasoning
    }

    public func encode(
        _ history: [AgentMessage], systemPrompt: String?, tools: [any AgentTool], supportsVision: Bool
    ) -> [String: Any] {
        let rendered = Self.renderMessages(
            systemPrompt: systemPrompt, messages: history, supportsVision: supportsVision
        )
        return Self.requestBody(
            model: model, messages: rendered, tools: tools.map { $0.toolSchema() },
            parameters: parameters, reasoning: reasoning
        )
    }

    public func makeDecoder() -> any TurnDecoder<String> { OpenAIDecoder() }

    // MARK: - Message rendering (encode)

    /// Render the conversation into the chat-completions `messages` array. The system prompt is
    /// the single leading `system` message (supplied separately, not part of `messages`); an
    /// assistant turn carries its tool calls as `tool_calls` with the framework `AgentToolCall.id`
    /// reused as the OpenAI string id, and a tool result is a `tool` turn whose `tool_call_id`
    /// matches - so the two stay correlated across rounds. For a vision model, a human turn with
    /// images uses the content-parts array (`{type:"text"}` + `{type:"image_url"}`), base64
    /// data-URL-encoding local file URLs.
    static func renderMessages(
        systemPrompt: String?,
        messages: [AgentMessage],
        supportsVision: Bool
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if let systemPrompt {
            result.append(["role": "system", "content": systemPrompt])
        }

        for message in messages {
            switch message.role {
            case .system:
                result.append(["role": "system", "content": message.text])
            case .human:
                if supportsVision, !message.images.isEmpty {
                    var parts: [[String: Any]] = [["type": "text", "text": message.text]]
                    for image in message.images {
                        if let part = imagePart(image) { parts.append(part) }
                    }
                    result.append(["role": "user", "content": parts])
                } else {
                    result.append(["role": "user", "content": message.text])
                }
            case .ai:
                var dict: [String: Any] = ["role": "assistant", "content": message.text]
                if !message.toolCalls.isEmpty {
                    dict["tool_calls"] = message.toolCalls.map { call -> [String: Any] in
                        [
                            "id": call.id.uuidString,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": encodeArguments(call.arguments)
                            ]
                        ]
                    }
                }
                result.append(dict)
            case .tool:
                result.append([
                    "role": "tool",
                    "tool_call_id": (message.toolCallID ?? message.id).uuidString,
                    "content": message.text
                ])
            }
        }
        return result
    }

    /// The chat-completions request body. Tools (already in `{type:"function", …}` shape) are
    /// passed through `jsonSafe` to flatten their `any Sendable` values to a plain JSON graph
    /// `JSONSerialization` accepts. Unset sampling params are omitted.
    static func requestBody(
        model: String,
        messages: [[String: Any]],
        tools: [ToolSchema],
        parameters: OpenAIGenerateParameters,
        reasoning: Bool = false
    ) -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        if !tools.isEmpty {
            body["tools"] = tools.map { jsonSafe($0) }
            body["tool_choice"] = "auto"
        }
        if let temperature = parameters.temperature { body["temperature"] = temperature }
        if let topP = parameters.topP { body["top_p"] = topP }
        if let maxTokens = parameters.maxTokens { body["max_tokens"] = maxTokens }
        if reasoning { body["reasoning"] = ["enabled": true] } // OpenRouter's unified reasoning param
        return body
    }

    /// Encode a tool call's arguments to the JSON string the chat-completions schema expects in
    /// `function.arguments`. Sorted keys for a deterministic rendering.
    static func encodeArguments(_ arguments: [String: AgentJSON]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(arguments), let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    /// One image content part for the chat-completions `content` array. Mirrors LangChain's
    /// `ImageContentBlock` sources: a `url` (a remote URL, or a local file inlined as base64),
    /// inline `base64` data as a `data:` URL, or a provider `fileID` as a `file` part. Nil for an
    /// empty image.
    static func imagePart(_ image: AgentImage) -> [String: Any]? {
        if let url = image.url {
            return ["type": "image_url", "image_url": ["url": imageURLString(url)]]
        }
        if let base64 = image.base64 {
            let mime = image.mimeType ?? "image/png"
            return ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(base64)"]]
        }
        if let fileID = image.fileID {
            return ["type": "file", "file": ["file_id": fileID]]
        }
        return nil
    }

    /// A remote image stays a URL; a local file is inlined as a base64 `data:` URL so the
    /// endpoint can see it without filesystem access.
    static func imageURLString(_ url: URL) -> String {
        if url.isFileURL, let data = try? Data(contentsOf: url) {
            return "data:\(mimeType(for: url));base64,\(data.base64EncodedString())"
        }
        return url.absoluteString
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// Recursively flatten an `any Sendable` JSON graph (the shape `ToolSchema` uses) to plain
    /// `Any` collections so `JSONSerialization` accepts it.
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dict as [String: any Sendable]: return dict.mapValues { jsonSafe($0) }
        case let array as [any Sendable]: return array.map { jsonSafe($0) }
        case let dict as [String: Any]: return dict.mapValues { jsonSafe($0) }
        case let array as [Any]: return array.map { jsonSafe($0) }
        default: return value
        }
    }

    // MARK: - SSE parsing (decode)

    /// The payload of an SSE `data:` line (the text after `data:`, a leading space trimmed), or
    /// nil for blank lines, comments, and other event fields.
    static func ssePayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count)
        return payload.hasPrefix(" ") ? String(payload.dropFirst()) : String(payload)
    }

    static func decodeChunk(_ payload: String) -> StreamChunk? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(StreamChunk.self, from: data)
    }

    /// One streamed chat-completions chunk (`choices[].delta`). Snake-case keys are mapped by the
    /// decoder's `.convertFromSnakeCase` strategy.
    struct StreamChunk: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let delta: Delta
        }

        struct Delta: Decodable {
            let content: String?
            /// Chain-of-thought: OpenRouter streams `reasoning`, DeepSeek streams `reasoning_content`
            /// (mapped here by `.convertFromSnakeCase`).
            let reasoning: String?
            let reasoningContent: String?
            let toolCalls: [ToolCallDelta]?
        }

        struct ToolCallDelta: Decodable {
            let index: Int
            let id: String?
            let function: FunctionDelta?
        }

        struct FunctionDelta: Decodable {
            let name: String?
            let arguments: String?
        }
    }
}

/// Reassembles the OpenAI SSE stream into one canonical assistant turn: `ingest` surfaces each
/// `delta.content` as visible `.text` and accumulates `delta.tool_calls`; `finish` parses the
/// accumulated tool calls into the canonical message.
public final class OpenAIDecoder: TurnDecoder {
    public typealias RawChunk = String

    private var text = ""
    private var reasoning = ""
    private var accumulator = ToolCallAccumulator()

    public init() {}

    public func ingest(_ line: String) -> [AgentStreamChunk] {
        guard let payload = OpenAIMessageCodec.ssePayload(line), payload != "[DONE]" else { return [] }
        guard let chunk = OpenAIMessageCodec.decodeChunk(payload), let choice = chunk.choices.first
        else { return [] }
        var pieces: [AgentStreamChunk] = []
        if let content = choice.delta.content, !content.isEmpty {
            text += content
            pieces.append(.text(content))
        }
        if let reasoningDelta = choice.delta.reasoning ?? choice.delta.reasoningContent,
           !reasoningDelta.isEmpty {
            reasoning += reasoningDelta
            pieces.append(.reasoning(reasoningDelta))
        }
        for delta in choice.delta.toolCalls ?? [] { accumulator.ingest(delta) }
        return pieces
    }

    public func finish() -> (stream: [AgentStreamChunk], message: AgentMessage) {
        let (calls, malformed) = accumulator.finish()
        let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([], .ai(
            text, toolCalls: calls, malformedToolCallBlocks: malformed,
            reasoning: trimmed.isEmpty ? nil : trimmed
        ))
    }
}

/// Reassembles streamed `tool_calls` deltas into `AgentToolCall`s. OpenAI streams each call by
/// `index`, sending the name once and the JSON `arguments` in fragments that concatenate; the
/// final argument string is parsed to `[String: AgentJSON]`. A call whose arguments don't parse
/// is reported as a malformed block so the ReAct loop can re-prompt instead of ending the run.
struct ToolCallAccumulator {
    private struct Partial {
        var name = ""
        var arguments = ""
    }

    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []

    mutating func ingest(_ delta: OpenAIMessageCodec.StreamChunk.ToolCallDelta) {
        if partials[delta.index] == nil {
            partials[delta.index] = Partial()
            order.append(delta.index)
        }
        if let name = delta.function?.name, !name.isEmpty { partials[delta.index]?.name += name }
        if let arguments = delta.function?.arguments { partials[delta.index]?.arguments += arguments }
    }

    func finish() -> (calls: [AgentToolCall], malformed: [String]) {
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
        return (calls, malformed)
    }

    /// Parse a `function.arguments` JSON string into the framework's argument map. Empty (a tool
    /// that takes no arguments) is a valid `{}`.
    static func parseArguments(_ string: String) -> [String: AgentJSON]? {
        if string.isEmpty { return [:] }
        guard let data = string.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String: AgentJSON].self, from: data)
        else { return nil }
        return parsed
    }
}
