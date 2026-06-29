import DeepAgents
import Foundation

/// The Anthropic Messages message codec: encodes the canonical ``AgentMessage`` history into a
/// Messages request body, and (via ``AnthropicDecoder``) decodes the streamed Server-Sent-Events
/// back into a canonical assistant turn. All Anthropic wire quirks (the `tool_use`/`tool_result`
/// block shapes, `image` source blocks, the top-level `system` field) live here; the turn session
/// keeps only the HTTP transport.
///
/// The static `render`/`tools` helpers and ``AnthropicDecoder`` are reused verbatim by the Bedrock
/// adapter, which speaks the same Messages wire format but assembles a Bedrock-flavored top-level
/// body (no `model`/`stream`, plus `anthropic_version: "bedrock-2023-05-31"`).
public struct AnthropicMessageCodec: MessageCodec {
    let model: String
    let parameters: AnthropicGenerateParameters

    public init(model: String, parameters: AnthropicGenerateParameters) {
        self.model = model
        self.parameters = parameters
    }

    public func encode(
        _ history: [AgentMessage], systemPrompt: String?, tools: [any AgentTool], supportsVision: Bool
    ) -> [String: Any] {
        let (system, messages) = Self.render(
            systemPrompt: systemPrompt, messages: history, supportsVision: supportsVision
        )
        return Self.requestBody(
            model: model, system: system, messages: messages, tools: Self.tools(tools),
            parameters: parameters, bedrock: false
        )
    }

    public func makeDecoder() -> any TurnDecoder<String> { AnthropicDecoder() }

    // MARK: - Body (encode)

    /// The Messages request body. Direct Anthropic carries `model` + `stream:true`; Bedrock omits
    /// both (the model is in the URL) and instead sends `anthropic_version: "bedrock-2023-05-31"`.
    /// `max_tokens` is always present (the API requires it); unset sampling params are omitted.
    static func requestBody(
        model: String, system: String?, messages: [[String: Any]], tools: [[String: Any]],
        parameters: AnthropicGenerateParameters, bedrock: Bool = false
    ) -> [String: Any] {
        var body: [String: Any] = ["messages": messages, "max_tokens": parameters.resolvedMaxTokens]
        if bedrock {
            body["anthropic_version"] = "bedrock-2023-05-31"
        } else {
            body["model"] = model
            body["stream"] = true
        }
        if let system, !system.isEmpty { body["system"] = system }
        if !tools.isEmpty { body["tools"] = tools }
        if let temperature = parameters.temperature { body["temperature"] = temperature }
        if let topP = parameters.topP { body["top_p"] = topP }
        return body
    }

    // MARK: - Message rendering (encode)

    /// Render the conversation into the top-level `system` string and the `messages` array.
    /// Anthropic has only `user`/`assistant`/`system` roles, so: a *leading* `.system` turn folds
    /// into the top-level system prompt, while a *mid-conversation* `.system` turn becomes a
    /// `role:"system"` message at its position (an operator instruction; Opus 4.8+); consecutive
    /// `.tool` results coalesce into one `user` turn of `tool_result` blocks (the API requires tool
    /// results in the user turn following the assistant's tool_use); the framework's own
    /// `AgentToolCall.id` round-trips as the `tool_use`/`tool_result` id.
    static func render(
        systemPrompt: String?, messages: [AgentMessage], supportsVision: Bool
    ) -> (system: String?, messages: [[String: Any]]) {
        var systemParts: [String] = []
        if let systemPrompt, !systemPrompt.isEmpty { systemParts.append(systemPrompt) }
        var result: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []
        func flush() {
            guard !pendingToolResults.isEmpty else { return }
            result.append(["role": "user", "content": pendingToolResults])
            pendingToolResults = []
        }
        for message in messages {
            switch message.role {
            case .system:
                if result.isEmpty, pendingToolResults.isEmpty {
                    if !message.text.isEmpty { systemParts.append(message.text) } // leading -> top-level system
                } else {
                    flush()
                    result.append(["role": "system", "content": message.text]) // mid-conversation operator turn
                }
            case .human:
                flush()
                result.append(["role": "user", "content": humanContent(message, supportsVision: supportsVision)])
            case .ai:
                flush()
                result.append(["role": "assistant", "content": assistantContent(message)])
            case .tool:
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": (message.toolCallID ?? message.id).uuidString,
                    "content": message.text
                ])
            }
        }
        flush()
        return (systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n"), result)
    }

    /// A human turn's `content`: a plain string, or - for a vision model with images - a parts
    /// array of a `{type:"text"}` block plus `image` blocks.
    static func humanContent(_ message: AgentMessage, supportsVision: Bool) -> Any {
        guard supportsVision, !message.images.isEmpty else { return message.text }
        var parts: [[String: Any]] = [["type": "text", "text": message.text]]
        for image in message.images {
            if let block = imageBlock(image) { parts.append(block) }
        }
        return parts
    }

    /// An assistant turn's `content`: a leading `text` block when non-empty, then a `tool_use`
    /// block per requested call (its `input` the parsed argument object). Falls back to a single
    /// text block so the content is never empty (the API rejects an empty content array).
    static func assistantContent(_ message: AgentMessage) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !message.text.isEmpty { blocks.append(["type": "text", "text": message.text]) }
        for call in message.toolCalls {
            blocks.append([
                "type": "tool_use", "id": call.id.uuidString, "name": call.name,
                "input": jsonObject(call.arguments)
            ])
        }
        if blocks.isEmpty { blocks.append(["type": "text", "text": message.text]) }
        return blocks
    }

    // MARK: - Tools (encode)

    /// Anthropic tool definitions `{name, description, input_schema}`, derived from each tool's
    /// `toolSchema()` (the OpenAI `{type:"function", function:{…}}` shape) by lifting the function's
    /// `name`/`description`/`parameters` - so the JSON-schema parameter object is reused verbatim.
    static func tools(_ tools: [any AgentTool]) -> [[String: Any]] {
        tools.map { tool in
            let schema = jsonSafe(tool.toolSchema()) as? [String: Any] ?? [:]
            let function = schema["function"] as? [String: Any] ?? [:]
            var out: [String: Any] = ["name": (function["name"] as? String) ?? tool.name]
            if let description = function["description"] as? String { out["description"] = description }
            out["input_schema"] = function["parameters"] ?? ["type": "object", "properties": [String: Any]()]
            return out
        }
    }

    // MARK: - Images (encode)

    /// One Anthropic `image` content block. Mirrors ``AgentImage``'s mutually-exclusive sources:
    /// a remote `url` (a local file is inlined as base64 so the endpoint needs no filesystem),
    /// inline `base64` data, or a provider `fileID`. Nil for an empty image.
    static func imageBlock(_ image: AgentImage) -> [String: Any]? {
        if let url = image.url {
            if url.isFileURL {
                // A local file must be inlined as base64; if it can't be read, drop it rather than
                // emit a `file://` URL the remote API can't fetch.
                guard let data = try? Data(contentsOf: url) else { return nil }
                return imageSource(type: "base64", ["media_type": mimeType(for: url), "data": data.base64EncodedString()])
            }
            return imageSource(type: "url", ["url": url.absoluteString])
        }
        if let base64 = image.base64 {
            return imageSource(type: "base64", ["media_type": image.mimeType ?? "image/png", "data": base64])
        }
        if let fileID = image.fileID {
            return imageSource(type: "file", ["file_id": fileID])
        }
        return nil
    }

    private static func imageSource(type: String, _ fields: [String: Any]) -> [String: Any] {
        var source: [String: Any] = ["type": type]
        source.merge(fields) { _, new in new }
        return ["type": "image", "source": source]
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    // MARK: - JSON helpers

    /// Convert a tool call's typed arguments into the plain JSON object the `tool_use.input` field
    /// expects (an object, not a string). Empty for a tool that takes no arguments.
    static func jsonObject(_ arguments: [String: AgentJSON]) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(arguments),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
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
}
