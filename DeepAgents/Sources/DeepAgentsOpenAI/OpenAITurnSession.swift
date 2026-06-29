import DeepAgents
import Foundation

/// One run's stateless model node for an OpenAI-compatible endpoint: each `nextTurn` encodes the
/// conversation (via ``OpenAIMessageCodec``), POSTs a streaming chat-completions request, and feeds
/// the Server-Sent-Events response back through the codec's decoder. This type owns only the HTTP
/// transport - the wire format lives in the codec.
///
/// A reference type only to satisfy `ModelTurnSession: AnyObject`; it holds no per-round state.
public final class OpenAITurnSession: ModelTurnSession {
    private let endpoint: URL
    private let apiKey: String?
    private let auth: OpenAIAuthStyle
    private let supportsVision: Bool
    private let codec: OpenAIMessageCodec
    private let transport: any OpenAIStreamingTransport

    init(
        endpoint: URL,
        apiKey: String?,
        auth: OpenAIAuthStyle = .bearer,
        supportsVision: Bool,
        codec: OpenAIMessageCodec,
        transport: any OpenAIStreamingTransport
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.auth = auth
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
        if let apiKey, !apiKey.isEmpty {
            switch auth {
            case .bearer: request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .apiKey: request.setValue(apiKey, forHTTPHeaderField: "api-key")
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (status, lines) = try await transport.send(request)

        // A non-2xx response is an error body, not SSE: drain it as text and surface it.
        guard (200 ..< 300).contains(status) else {
            var errorBody = ""
            for try await line in lines { errorBody += line + "\n" }
            throw OpenAIModelError.http(
                status: status, body: errorBody.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let decoder = codec.makeDecoder()
        for try await line in lines {
            for piece in decoder.ingest(line) { onChunk(piece) }
        }
        let (trailing, message) = decoder.finish()
        for piece in trailing { onChunk(piece) }
        return message
    }
}
