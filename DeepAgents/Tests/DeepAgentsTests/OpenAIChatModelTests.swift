@testable import DeepAgents
@testable import DeepAgentsOpenAI
import Foundation
import Testing

/// Tests the OpenAI-compatible adapter's pure seams - message rendering, request-body shape,
/// SSE payload extraction, streamed `tool_calls` reassembly - plus one end-to-end `nextTurn`
/// driven by a stub transport feeding canned Server-Sent-Events (no network).
struct OpenAIChatModelTests {
    // MARK: - Rendering

    @Test func rendersRolesAndCorrelatesToolCallWithItsResult() {
        let callID = UUID()
        let call = AgentToolCall(id: callID, name: "echo", arguments: ["text": .string("hi")])
        let rendered = OpenAIMessageCodec.renderMessages(
            systemPrompt: "sys",
            messages: [.human("hello"), .ai("", toolCalls: [call]), .tool("echo: hi", toolCallID: callID)],
            supportsVision: false
        )

        #expect(rendered.count == 4)
        #expect(rendered[0]["role"] as? String == "system")
        #expect(rendered[0]["content"] as? String == "sys")
        #expect(rendered[1]["role"] as? String == "user")
        #expect(rendered[1]["content"] as? String == "hello")

        #expect(rendered[2]["role"] as? String == "assistant")
        let toolCalls = rendered[2]["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.count == 1)
        #expect(toolCalls?.first?["id"] as? String == callID.uuidString)
        #expect(toolCalls?.first?["type"] as? String == "function")
        let function = toolCalls?.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "echo")
        #expect(function?["arguments"] as? String == "{\"text\":\"hi\"}")

        // The tool result's tool_call_id matches the assistant call's id, so the round-trip stays
        // correlated for the next request.
        #expect(rendered[3]["role"] as? String == "tool")
        #expect(rendered[3]["tool_call_id"] as? String == callID.uuidString)
        #expect(rendered[3]["content"] as? String == "echo: hi")
    }

    @Test func visionTurnUsesImageContentParts() throws {
        let url = try #require(URL(string: "https://example.com/shot.png"))
        let rendered = OpenAIMessageCodec.renderMessages(
            systemPrompt: nil,
            messages: [.human("look", imageURLs: [url])],
            supportsVision: true
        )
        let parts = rendered[0]["content"] as? [[String: Any]]
        #expect(parts?.count == 2)
        #expect(parts?.first?["type"] as? String == "text")
        #expect(parts?.first?["text"] as? String == "look")
        #expect(parts?.last?["type"] as? String == "image_url")
        let imageURL = parts?.last?["image_url"] as? [String: Any]
        #expect(imageURL?["url"] as? String == "https://example.com/shot.png")
    }

    @Test func base64ImageBecomesDataURLPart() {
        let message = AgentMessage.human("look", images: [AgentImage(base64: "QUJD", mimeType: "image/png")])
        let rendered = OpenAIMessageCodec.renderMessages(
            systemPrompt: nil, messages: [message], supportsVision: true
        )
        let parts = rendered[0]["content"] as? [[String: Any]]
        let imageURL = parts?.last?["image_url"] as? [String: Any]
        #expect(imageURL?["url"] as? String == "data:image/png;base64,QUJD")
    }

    @Test func fileIDImageBecomesFilePart() {
        let message = AgentMessage.human("look", images: [AgentImage(fileID: "file-123")])
        let rendered = OpenAIMessageCodec.renderMessages(
            systemPrompt: nil, messages: [message], supportsVision: true
        )
        let parts = rendered[0]["content"] as? [[String: Any]]
        #expect(parts?.last?["type"] as? String == "file")
        #expect((parts?.last?["file"] as? [String: Any])?["file_id"] as? String == "file-123")
    }

    @Test func textModelIgnoresImages() throws {
        let url = try #require(URL(string: "https://example.com/shot.png"))
        let rendered = OpenAIMessageCodec.renderMessages(
            systemPrompt: nil,
            messages: [.human("look", imageURLs: [url])],
            supportsVision: false
        )
        #expect(rendered[0]["content"] as? String == "look")
    }

    // MARK: - Request body

    @Test func requestBodyCarriesToolsAndSamplingAndIsSerializable() throws {
        let body = OpenAIMessageCodec.requestBody(
            model: "gpt-x",
            messages: [["role": "user", "content": "hi"]],
            tools: [EchoTool().toolSchema()],
            parameters: .init(temperature: 0.2, maxTokens: 100)
        )
        #expect(body["model"] as? String == "gpt-x")
        #expect(body["stream"] as? Bool == true)
        #expect((body["tools"] as? [Any])?.count == 1)
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["max_tokens"] as? Int == 100)
        #expect(body["top_p"] == nil)

        // The flattened tool schema must survive JSONSerialization (the live request encodes it).
        #expect(JSONSerialization.isValidJSONObject(body))
        _ = try JSONSerialization.data(withJSONObject: body)
    }

    @Test func requestBodyOmitsToolsWhenNoneAndUnsetSampling() {
        let body = OpenAIMessageCodec.requestBody(
            model: "gpt-x",
            messages: [["role": "user", "content": "hi"]],
            tools: [],
            parameters: .init()
        )
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
        #expect(body["temperature"] == nil)
        #expect(body["max_tokens"] == nil)
    }

    // MARK: - SSE + accumulation

    @Test func ssePayloadStripsDataPrefix() {
        #expect(OpenAIMessageCodec.ssePayload("data: {\"a\":1}") == "{\"a\":1}")
        #expect(OpenAIMessageCodec.ssePayload("data:[DONE]") == "[DONE]")
        #expect(OpenAIMessageCodec.ssePayload(": keep-alive comment") == nil)
        #expect(OpenAIMessageCodec.ssePayload("") == nil)
    }

    @Test func accumulatorReassemblesStreamedToolCall() {
        var accumulator = ToolCallAccumulator()
        accumulator.ingest(.init(index: 0, id: "call_1", function: .init(name: "echo", arguments: "{\"text\":")))
        accumulator.ingest(.init(index: 0, id: nil, function: .init(name: nil, arguments: "\"hi\"}")))
        let (calls, malformed) = accumulator.finish()
        #expect(calls.count == 1)
        #expect(calls.first?.name == "echo")
        #expect(calls.first?.arguments["text"] == .string("hi"))
        #expect(malformed.isEmpty)
    }

    @Test func accumulatorFlagsUnparseableArgumentsAsMalformed() {
        var accumulator = ToolCallAccumulator()
        accumulator.ingest(.init(index: 0, id: "call_1", function: .init(name: "bad", arguments: "{not json")))
        let (calls, malformed) = accumulator.finish()
        #expect(calls.isEmpty)
        #expect(malformed.count == 1)
    }

    @Test func argumentEncodeParseRoundTrips() {
        let arguments: [String: AgentJSON] = ["text": .string("hi"), "count": .int(3), "flag": .bool(true)]
        let encoded = OpenAIMessageCodec.encodeArguments(arguments)
        #expect(ToolCallAccumulator.parseArguments(encoded) == arguments)
    }

    // MARK: - nextTurn end-to-end

    @Test func nextTurnStreamsTextAndParsesToolCall() async throws {
        let lines = [
            sse(["choices": [["delta": ["content": "Hel"]]]]),
            sse(["choices": [["delta": ["content": "lo"]]]]),
            sse(["choices": [["delta": ["tool_calls": [
                ["index": 0, "id": "call_1", "function": ["name": "echo", "arguments": "{\"text\":"]]
            ]]]]]),
            sse(["choices": [["delta": ["tool_calls": [
                ["index": 0, "function": ["arguments": "\"hi\"}"]]
            ]]]]]),
            "data: [DONE]"
        ]
        let model = try OpenAIChatModel(
            baseURL: #require(URL(string: "https://example.com/v1")), model: "gpt-x",
            transport: StubTransport(status: 200, lines: lines)
        )
        let collector = TokenCollector()
        let message = try await model.makeSession().nextTurn(
            messages: [.human("hi")], systemPrompt: "sys", tools: [EchoTool()]
        ) { if case .text(let token) = $0 { collector.append(token) } }

        #expect(collector.text == "Hello")
        #expect(message.text == "Hello")
        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls.first?.name == "echo")
        #expect(message.toolCalls.first?.arguments["text"] == .string("hi"))
    }

    @Test func nextTurnThrowsOnErrorStatus() async throws {
        let model = try OpenAIChatModel(
            baseURL: #require(URL(string: "https://example.com/v1")), model: "gpt-x",
            transport: StubTransport(status: 401, lines: ["{\"error\":\"bad key\"}"])
        )
        await #expect(throws: OpenAIModelError.self) {
            _ = try await model.makeSession().nextTurn(
                messages: [.human("hi")], systemPrompt: nil, tools: []
            ) { _ in }
        }
    }

    // MARK: - Reasoning

    @Test func decoderSurfacesReasoningField() {
        let decoder = OpenAIDecoder()
        var pieces: [AgentStreamChunk] = []
        pieces += decoder.ingest(sse(["choices": [["delta": ["reasoning": "thinking"]]]]))
        pieces += decoder.ingest(sse(["choices": [["delta": ["content": "answer"]]]]))
        let (_, message) = decoder.finish()

        let reasoning = pieces.compactMap { if case .reasoning(let value) = $0 { value } else { nil } }.joined()
        #expect(reasoning == "thinking")
        #expect(message.reasoning == "thinking")
        #expect(message.text == "answer")
    }

    @Test func decoderSurfacesReasoningContentField() {
        let decoder = OpenAIDecoder()
        _ = decoder.ingest(sse(["choices": [["delta": ["reasoning_content": "deepseek-style"]]]]))
        let (_, message) = decoder.finish()
        #expect(message.reasoning == "deepseek-style")
    }

    @Test func requestBodyAddsReasoningParamWhenEnabled() {
        let body = OpenAIMessageCodec.requestBody(
            model: "m", messages: [], tools: [], parameters: .init(), reasoning: true
        )
        #expect((body["reasoning"] as? [String: Any])?["enabled"] as? Bool == true)
        let off = OpenAIMessageCodec.requestBody(
            model: "m", messages: [], tools: [], parameters: .init(), reasoning: false
        )
        #expect(off["reasoning"] == nil)
    }

    // MARK: - Decoder edge cases

    /// Drive an `OpenAIDecoder` with raw SSE lines; return streamed pieces + the final message.
    private func decode(_ lines: [String]) -> (pieces: [AgentStreamChunk], message: AgentMessage) {
        let decoder = OpenAIDecoder()
        var pieces: [AgentStreamChunk] = []
        for line in lines { pieces += decoder.ingest(line) }
        let (trailing, message) = decoder.finish()
        return (pieces + trailing, message)
    }

    @Test func noiseAndDoneLinesProduceNoPieces() {
        let decoder = OpenAIDecoder()
        #expect(decoder.ingest(": keep-alive comment").isEmpty)
        #expect(decoder.ingest("").isEmpty)
        #expect(decoder.ingest("data: [DONE]").isEmpty)
        #expect(decoder.ingest(sse(["choices": [["delta": ["content": "hi"]]]])).count == 1)
        #expect(decoder.finish().message.text == "hi")
    }

    @Test func malformedJSONLineIsSkipped() {
        let (_, message) = decode(["data: {not json", sse(["choices": [["delta": ["content": "ok"]]]])])
        #expect(message.text == "ok")
    }

    @Test func emptyChoicesIsSkipped() {
        let (_, message) = decode([sse(["choices": []]), sse(["choices": [["delta": ["content": "ok"]]]])])
        #expect(message.text == "ok")
    }

    @Test func reasoningFieldWinsOverReasoningContent() {
        let (_, message) = decode([
            sse(["choices": [["delta": ["reasoning": "primary", "reasoning_content": "secondary"]]]])
        ])
        #expect(message.reasoning == "primary")
    }

    /// An SSE line carrying one streamed `tool_calls` delta (built without deep bracket nesting).
    private func toolCallSSE(index: Int, name: String? = nil, arguments: String? = nil) -> String {
        var function: [String: Any] = [:]
        if let name { function["name"] = name }
        if let arguments { function["arguments"] = arguments }
        var call: [String: Any] = ["index": index]
        if !function.isEmpty { call["function"] = function }
        return sse(["choices": [["delta": ["tool_calls": [call]]]]])
    }

    @Test func toolNameSplitAcrossDeltasReassembles() {
        let (_, message) = decode([
            toolCallSSE(index: 0, name: "ec"),
            toolCallSSE(index: 0, name: "ho", arguments: "{}")
        ])
        #expect(message.toolCalls.first?.name == "echo")
        #expect(message.toolCalls.first?.arguments.isEmpty == true)
    }

    @Test func interleavedToolCallIndexesKeepOrder() {
        let (_, message) = decode([
            toolCallSSE(index: 0, name: "a", arguments: "{}"),
            toolCallSSE(index: 1, name: "b", arguments: "{}"),
            toolCallSSE(index: 0, arguments: "")
        ])
        #expect(message.toolCalls.map(\.name) == ["a", "b"])
    }

    // MARK: - renderMessages edge cases

    @Test func toolMessageWithoutToolCallIDFallsBackToMessageID() {
        let message = AgentMessage(role: .tool, content: [.text("result")]) // no toolCallID
        let rendered = OpenAIMessageCodec.renderMessages(
            systemPrompt: nil, messages: [message], supportsVision: false
        )
        #expect(rendered[0]["tool_call_id"] as? String == message.id.uuidString)
    }

    @Test func mixedImageSourcesRenderDistinctParts() {
        let images = [
            AgentImage(url: URL(string: "https://example.com/a.png")),
            AgentImage(base64: "QUJD", mimeType: "image/jpeg"),
            AgentImage(fileID: "file-9")
        ]
        let rendered = OpenAIMessageCodec.renderMessages(
            systemPrompt: nil, messages: [.human("look", images: images)], supportsVision: true
        )
        let parts = rendered[0]["content"] as? [[String: Any]]
        #expect(parts?.count == 4) // text + 3 images
        #expect((parts?[1]["image_url"] as? [String: Any])?["url"] as? String == "https://example.com/a.png")
        #expect((parts?[2]["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64,QUJD")
        #expect(parts?[3]["type"] as? String == "file")
    }

    @Test func missingFileURLFallsBackToItsString() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).png")
        let rendered = OpenAIMessageCodec.renderMessages(
            systemPrompt: nil, messages: [.human("look", imageURLs: [url])], supportsVision: true
        )
        let parts = rendered[0]["content"] as? [[String: Any]]
        #expect((parts?.last?["image_url"] as? [String: Any])?["url"] as? String == url.absoluteString)
    }

    // MARK: - Session-level reasoning + request wiring

    @Test func nextTurnSurfacesReasoningOnItsChannel() async throws {
        let reasoning = TokenCollector()
        let answer = TokenCollector()
        let model = try OpenAIChatModel(
            baseURL: #require(URL(string: "https://example.com/v1")), model: "gpt-x",
            transport: StubTransport(status: 200, lines: [
                sse(["choices": [["delta": ["reasoning": "the thinking"]]]]),
                sse(["choices": [["delta": ["content": "the answer"]]]]),
                "data: [DONE]"
            ])
        )
        let message = try await model.makeSession().nextTurn(
            messages: [.human("hi")], systemPrompt: nil, tools: []
        ) {
            switch $0 {
            case .reasoning(let value): reasoning.append(value)
            case .text(let value): answer.append(value)
            }
        }
        #expect(reasoning.text == "the thinking")
        #expect(answer.text == "the answer")
        #expect(message.reasoning == "the thinking")
        #expect(message.text == "the answer")
    }

    @Test func singleDeltaWithContentAndReasoningEmitsBoth() {
        let (pieces, message) = decode([sse(["choices": [["delta": ["content": "ans", "reasoning": "think"]]]])])
        #expect(pieces.contains { if case .text("ans") = $0 { return true } else { return false } })
        #expect(pieces.contains { if case .reasoning("think") = $0 { return true } else { return false } })
        #expect(message.text == "ans")
        #expect(message.reasoning == "think")
    }

    @Test func reasoningEnabledModelSendsReasoningParam() async throws {
        let transport = CapturingTransport()
        let model = try OpenAIChatModel(
            baseURL: #require(URL(string: "https://h/v1")), model: "m", reasoning: true, transport: transport
        )
        _ = try await model.makeSession().nextTurn(messages: [.human("hi")], systemPrompt: nil, tools: []) { _ in }
        #expect((transport.requestJSON?["reasoning"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    @Test func reasoningDisabledModelOmitsReasoningParam() async throws {
        let transport = CapturingTransport()
        let model = try OpenAIChatModel(
            baseURL: #require(URL(string: "https://h/v1")), model: "m", reasoning: false, transport: transport
        )
        _ = try await model.makeSession().nextTurn(messages: [.human("hi")], systemPrompt: nil, tools: []) { _ in }
        #expect(transport.requestJSON?["reasoning"] == nil)
    }

    // MARK: - Helpers

    /// A `data:` SSE line carrying `object` as JSON.
    private func sse(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else { return "data: {}" }
        return "data: " + string
    }
}

/// A transport that replays canned status + lines, so `nextTurn` runs without a network.
private struct StubTransport: OpenAIStreamingTransport {
    let status: Int
    let lines: [String]

    func send(
        _: URLRequest
    ) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let captured = lines
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in captured { continuation.yield(line) }
            continuation.finish()
        }
        return (status, stream)
    }
}

/// A transport that records the request body (and returns an empty stream), so a test can assert
/// exactly what the codec put on the wire.
private final class CapturingTransport: OpenAIStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var body: Data?

    var requestJSON: [String: Any]? {
        guard let captured = lock.withLock({ body }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: captured)) as? [String: Any]
    }

    func send(
        _ request: URLRequest
    ) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        lock.withLock { body = request.httpBody }
        return (200, AsyncThrowingStream { $0.finish() })
    }
}

/// A thread-safe sink for the `@Sendable` token callback.
private final class TokenCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) {
        lock.lock()
        buffer += chunk
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
