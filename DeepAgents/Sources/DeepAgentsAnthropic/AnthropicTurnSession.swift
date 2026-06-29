import DeepAgents
import Foundation

/// One run's stateless model node for the Anthropic Messages API: each `nextTurn` encodes the
/// conversation (via ``AnthropicMessageCodec``), POSTs a streaming request, and feeds the
/// Server-Sent-Events response back through the codec's decoder. This type owns only the HTTP
/// transport - the wire format lives in the codec.
///
/// A reference type only to satisfy `ModelTurnSession: AnyObject`; it holds no per-round state.
public final class AnthropicTurnSession: ModelTurnSession {
    private let endpoint: URL
    private let apiKey: String?
    private let anthropicVersion: String
    private let betaHeaders: [String]
    private let supportsVision: Bool
    private let codec: AnthropicMessageCodec
    private let transport: any AnthropicStreamingTransport

    init(
        endpoint: URL,
        apiKey: String?,
        anthropicVersion: String,
        betaHeaders: [String],
        supportsVision: Bool,
        codec: AnthropicMessageCodec,
        transport: any AnthropicStreamingTransport
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.anthropicVersion = anthropicVersion
        self.betaHeaders = betaHeaders
        self.supportsVision = supportsVision
        self.codec = codec
        self.transport = transport
    }

    public func nextTurn(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [any AgentTool],
        onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
    ) async throws -> AgentMessage {
        let body = codec.encode(
            messages, systemPrompt: systemPrompt, tools: tools, supportsVision: supportsVision
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        if !betaHeaders.isEmpty {
            request.setValue(betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (status, lines) = try await transport.send(request)

        // A non-2xx response is an error body, not SSE: drain it as text and surface it.
        guard (200 ..< 300).contains(status) else {
            var errorBody = ""
            for try await line in lines { errorBody += line + "\n" }
            throw AnthropicModelError.http(
                status: status, body: errorBody.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let decoder = AnthropicDecoder()
        for try await line in lines {
            for piece in decoder.ingest(line) { onChunk(piece) }
        }
        // An `error` event after the 200 is a failed turn, not a (truncated) success - surface it.
        if let streamError = decoder.streamError { throw AnthropicModelError.stream(streamError) }
        let (trailing, message) = decoder.finish()
        for piece in trailing { onChunk(piece) }
        return message
    }
}
