@testable import DeepAgents
@testable import DeepAgentsAnthropic
import Foundation
import Testing

/// Tests the Anthropic Messages adapter's pure seams - role mapping (incl. `.tool` coalescing into a
/// single user turn of `tool_result` blocks), the Anthropic `input_schema` tool shape, request-body
/// assembly - plus the streamed decoder and one end-to-end `nextTurn` over a stub transport.
struct AnthropicChatModelTests {
    // MARK: - Rendering

    @Test func coalescesToolResultsIntoOneUserTurn() {
        let id1 = UUID()
        let id2 = UUID()
        let (system, messages) = AnthropicMessageCodec.render(
            systemPrompt: "sys",
            messages: [
                .human("hi"),
                .ai("", toolCalls: [
                    AgentToolCall(id: id1, name: "a", arguments: [:]),
                    AgentToolCall(id: id2, name: "b", arguments: ["x": .int(1)])
                ]),
                .tool("ra", toolCallID: id1),
                .tool("rb", toolCallID: id2)
            ],
            supportsVision: false
        )

        #expect(system == "sys")
        #expect(messages.count == 3) // user(hi), assistant(2x tool_use), user(2x tool_result)

        let assistant = messages[1]
        #expect(assistant["role"] as? String == "assistant")
        let blocks = assistant["content"] as? [[String: Any]]
        #expect(blocks?.count == 2) // two tool_use blocks, no text block (text is empty)
        #expect(blocks?.first?["type"] as? String == "tool_use")
        #expect(blocks?.first?["id"] as? String == id1.uuidString)
        #expect(blocks?.first?["name"] as? String == "a")
        #expect((blocks?.last?["input"] as? [String: Any])?["x"] as? Int == 1)

        let toolTurn = messages[2]
        #expect(toolTurn["role"] as? String == "user")
        let results = toolTurn["content"] as? [[String: Any]]
        #expect(results?.count == 2)
        #expect(results?.first?["type"] as? String == "tool_result")
        #expect(results?.first?["tool_use_id"] as? String == id1.uuidString)
        #expect(results?.first?["content"] as? String == "ra")
        #expect(results?.last?["tool_use_id"] as? String == id2.uuidString)
    }

    @Test func foldsSystemRoleMessagesIntoSystem() {
        let (system, messages) = AnthropicMessageCodec.render(
            systemPrompt: "base", messages: [.system("extra"), .human("hi")], supportsVision: false
        )
        #expect(system == "base\n\nextra")
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
    }

    @Test func toolsUseAnthropicInputSchemaShape() {
        let tools = AnthropicMessageCodec.tools([EchoTool()])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "echo")
        #expect(tools[0]["description"] as? String == "Echo the given text.")
        let schema = tools[0]["input_schema"] as? [String: Any]
        #expect(schema?["type"] as? String == "object")
        #expect((schema?["properties"] as? [String: Any])?["text"] != nil)
        // Anthropic shape, not the OpenAI `{type:"function", function:{…}}` wrapper.
        #expect(tools[0]["function"] == nil)
        #expect(tools[0]["type"] == nil)
    }

    @Test func visionTurnUsesImageBlocks() throws {
        let url = try #require(URL(string: "https://example.com/a.png"))
        let (_, messages) = AnthropicMessageCodec.render(
            systemPrompt: nil, messages: [.human("look", imageURLs: [url])], supportsVision: true
        )
        let parts = messages[0]["content"] as? [[String: Any]]
        #expect(parts?.count == 2)
        #expect(parts?.first?["type"] as? String == "text")
        let image = parts?.last
        #expect(image?["type"] as? String == "image")
        let source = image?["source"] as? [String: Any]
        #expect(source?["type"] as? String == "url")
        #expect(source?["url"] as? String == "https://example.com/a.png")
    }

    @Test func requestBodyShapeDiffersForBedrock() {
        let direct = AnthropicMessageCodec.requestBody(
            model: "claude-x", system: "sys", messages: [], tools: [], parameters: .init()
        )
        #expect(direct["model"] as? String == "claude-x")
        #expect(direct["stream"] as? Bool == true)
        #expect(direct["max_tokens"] as? Int == 4096) // required default
        #expect(direct["anthropic_version"] == nil)

        let bedrock = AnthropicMessageCodec.requestBody(
            model: "claude-x", system: "sys", messages: [], tools: [],
            parameters: .init(maxTokens: 1024), bedrock: true
        )
        #expect(bedrock["model"] == nil) // the model is in the URL on Bedrock
        #expect(bedrock["stream"] == nil)
        #expect(bedrock["anthropic_version"] as? String == "bedrock-2023-05-31")
        #expect(bedrock["max_tokens"] as? Int == 1024)
    }

    // MARK: - Decoder

    @Test func decoderStreamsTextThinkingAndToolCall() {
        let decoder = AnthropicDecoder()
        var pieces: [AgentStreamChunk] = []
        pieces += decoder.ingest(event(["type": "content_block_start", "index": 0,
                                        "content_block": ["type": "text"]]))
        pieces += decoder.ingest(event(["type": "content_block_delta", "index": 0,
                                        "delta": ["type": "text_delta", "text": "Hello"]]))
        pieces += decoder.ingest(event(["type": "content_block_start", "index": 1,
                                        "content_block": ["type": "thinking"]]))
        pieces += decoder.ingest(event(["type": "content_block_delta", "index": 1,
                                        "delta": ["type": "thinking_delta", "thinking": "hmm"]]))
        pieces += decoder.ingest(event(["type": "content_block_start", "index": 2,
                                        "content_block": ["type": "tool_use", "id": "toolu_1", "name": "echo"]]))
        pieces += decoder.ingest(event(["type": "content_block_delta", "index": 2,
                                        "delta": ["type": "input_json_delta", "partial_json": "{\"text\":"]]))
        pieces += decoder.ingest(event(["type": "content_block_delta", "index": 2,
                                        "delta": ["type": "input_json_delta", "partial_json": "\"hi\"}"]]))
        pieces += decoder.ingest(event(["type": "content_block_stop", "index": 2]))
        let (_, message) = decoder.finish()

        #expect(message.text == "Hello")
        #expect(message.reasoning == "hmm")
        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls.first?.name == "echo")
        #expect(message.toolCalls.first?.arguments["text"] == .string("hi"))
        #expect(pieces.contains { if case .text("Hello") = $0 { true } else { false } })
        #expect(pieces.contains { if case .reasoning("hmm") = $0 { true } else { false } })
    }

    @Test func decoderIgnoresEventLinesAndNoise() {
        let decoder = AnthropicDecoder()
        #expect(decoder.ingest("event: content_block_delta").isEmpty)
        #expect(decoder.ingest("").isEmpty)
        #expect(decoder.ingest(event(["type": "content_block_delta", "index": 0,
                                      "delta": ["type": "text_delta", "text": "ok"]])).count == 1)
        #expect(decoder.finish().message.text == "ok")
    }

    // MARK: - nextTurn end-to-end

    @Test func nextTurnStreamsTextAndBuildsBodyAndHeaders() async throws {
        let url = try #require(URL(string: "https://api.anthropic.com"))
        let transport = StubAnthropicTransport(status: 200, lines: [
            event(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hel"]]),
            event(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "lo"]]),
            event(["type": "message_stop"])
        ])
        let model = AnthropicChatModel(baseURL: url, model: "claude-x", apiKey: "k", transport: transport)
        let collector = TextSink()
        let message = try await model.makeSession().nextTurn(
            messages: [.human("hi")], systemPrompt: "sys", tools: []
        ) { if case .text(let token) = $0 { collector.append(token) } }

        #expect(collector.text == "Hello")
        #expect(message.text == "Hello")
        #expect(transport.requestJSON?["model"] as? String == "claude-x")
        #expect(transport.requestJSON?["stream"] as? Bool == true)
        #expect(transport.requestJSON?["system"] as? String == "sys")
        #expect(transport.headers?["x-api-key"] == "k")
        #expect(transport.headers?["anthropic-version"] == "2023-06-01")
    }

    @Test func nextTurnThrowsOnErrorStatus() async throws {
        let url = try #require(URL(string: "https://api.anthropic.com"))
        let model = AnthropicChatModel(
            baseURL: url, model: "claude-x",
            transport: StubAnthropicTransport(status: 401, lines: ["{\"error\":\"bad key\"}"])
        )
        await #expect(throws: AnthropicModelError.self) {
            _ = try await model.makeSession().nextTurn(
                messages: [.human("hi")], systemPrompt: nil, tools: []
            ) { _ in }
        }
    }

    // MARK: - Stream errors

    @Test func decoderRecordsStreamError() {
        let decoder = AnthropicDecoder()
        _ = decoder.ingest(event(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]))
        #expect(decoder.streamError == "Overloaded")
    }

    @Test func nextTurnThrowsOnStreamError() async throws {
        let url = try #require(URL(string: "https://api.anthropic.com"))
        let model = AnthropicChatModel(baseURL: url, model: "claude-x", transport: StubAnthropicTransport(
            status: 200,
            lines: [
                event(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "partial"]]),
                event(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]])
            ]
        ))
        await #expect(throws: AnthropicModelError.self) {
            _ = try await model.makeSession().nextTurn(
                messages: [.human("hi")], systemPrompt: nil, tools: []
            ) { _ in }
        }
    }

    @Test func decoderReportsMalformedToolCall() {
        let decoder = AnthropicDecoder()
        _ = decoder.ingest(event(["type": "content_block_start", "index": 0,
                                  "content_block": ["type": "tool_use", "id": "toolu_1", "name": "echo"]]))
        _ = decoder.ingest(event(["type": "content_block_delta", "index": 0,
                                  "delta": ["type": "input_json_delta", "partial_json": "{not json"]]))
        _ = decoder.ingest(event(["type": "content_block_stop", "index": 0]))
        let (_, message) = decoder.finish()
        #expect(message.toolCalls.isEmpty)
        #expect(message.malformedToolCallBlocks.count == 1)
        #expect(message.malformedToolCallBlocks.first?.contains("echo") == true)
    }

    // MARK: - Images + mid-conversation system

    @Test func base64ImageRendersBase64Source() {
        let block = AnthropicMessageCodec.imageBlock(AgentImage(base64: "QUJD", mimeType: "image/jpeg"))
        #expect(block?["type"] as? String == "image")
        let source = block?["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/jpeg")
        #expect(source?["data"] as? String == "QUJD")
    }

    @Test func fileIDImageRendersFileSource() {
        let source = AnthropicMessageCodec.imageBlock(AgentImage(fileID: "file-9"))?["source"] as? [String: Any]
        #expect(source?["type"] as? String == "file")
        #expect(source?["file_id"] as? String == "file-9")
    }

    @Test func unreadableLocalImageIsDropped() {
        let missing = URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString).png")
        #expect(AnthropicMessageCodec.imageBlock(AgentImage(url: missing)) == nil)
        // It's omitted from the rendered human content rather than becoming an unfetchable file:// block.
        let (_, messages) = AnthropicMessageCodec.render(
            systemPrompt: nil, messages: [.human("look", images: [AgentImage(url: missing)])], supportsVision: true
        )
        #expect((messages[0]["content"] as? [[String: Any]])?.count == 1) // text only
    }

    @Test func midConversationSystemBecomesSystemRole() {
        let (system, messages) = AnthropicMessageCodec.render(
            systemPrompt: "base",
            messages: [.human("hi"), .ai("ok"), .system("note"), .human("more")],
            supportsVision: false
        )
        #expect(system == "base") // only the top-level prompt; the mid-conversation system stays inline
        #expect(messages.count == 4)
        #expect(messages[2]["role"] as? String == "system")
        #expect(messages[2]["content"] as? String == "note")
    }

    // MARK: - Helpers

    /// A `data:` SSE line carrying `object` as JSON (one Anthropic Messages event).
    private func event(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else { return "data: {}" }
        return "data: " + string
    }
}

/// A transport that records the request body + headers and replays canned SSE lines (no network).
private final class StubAnthropicTransport: AnthropicStreamingTransport, @unchecked Sendable {
    let status: Int
    let lines: [String]
    private let lock = NSLock()
    private var body: Data?
    private var capturedHeaders: [String: String]?

    init(status: Int, lines: [String]) {
        self.status = status
        self.lines = lines
    }

    var requestJSON: [String: Any]? {
        guard let captured = lock.withLock({ body }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: captured)) as? [String: Any]
    }

    var headers: [String: String]? { lock.withLock { capturedHeaders } }

    func send(
        _ request: URLRequest
    ) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        lock.withLock {
            body = request.httpBody
            capturedHeaders = request.allHTTPHeaderFields
        }
        let captured = lines
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in captured { continuation.yield(line) }
            continuation.finish()
        }
        return (status, stream)
    }
}

/// A thread-safe sink for the `@Sendable` token callback.
private final class TextSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ chunk: String) { lock.withLock { buffer += chunk } }
    var text: String { lock.withLock { buffer } }
}
