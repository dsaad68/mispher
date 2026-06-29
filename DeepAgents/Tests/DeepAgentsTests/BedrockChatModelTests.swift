@testable import DeepAgents
@testable import DeepAgentsAnthropic
import Foundation
import Testing

/// Tests the Bedrock adapter's pure seams: the SigV4 signing key against AWS's published vector, the
/// signed-header structure, the model-id path encoding, the `vnd.amazon.eventstream` frame parser
/// (incl. reassembly across chunk boundaries), and one end-to-end `nextTurn` over canned frames.
struct BedrockChatModelTests {
    // MARK: - SigV4

    /// AWS documents this exact derived signing key for these inputs (SigV4 docs), so it's a real
    /// known-answer check on the HMAC chain - not just a behavior lock.
    @Test func derivedSigningKeyMatchesAWSVector() {
        let key = SigV4.derivedKey(
            secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            dateStamp: "20150830", region: "us-east-1", service: "iam"
        )
        let hex = key.withUnsafeBytes { SigV4.hex($0) }
        #expect(hex == "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
    }

    @Test func signAddsSigV4HeadersIncludingSessionToken() throws {
        let url = try #require(URL(string:
            "https://bedrock-runtime.us-east-1.amazonaws.com/model/m/invoke-with-response-stream"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let credentials = BedrockCredentials(accessKey: "AKIDEXAMPLE", secretKey: "secret", sessionToken: "tok")
        let date = try fixedUTCDate(year: 2015, month: 8, day: 30, hour: 12, minute: 36)

        SigV4.sign(&request, body: Data("{}".utf8), credentials: credentials, region: "us-east-1", date: date)

        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasPrefix(
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/bedrock/aws4_request"
        ))
        #expect(auth.contains("SignedHeaders=host;x-amz-date;x-amz-security-token"))
        #expect(auth.contains("Signature="))
        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "tok")
    }

    /// Full end-to-end signature against AWS's `aws-sig-v4-test-suite` `get-vanilla` vector - proves
    /// the whole canonical request (URI, headers, empty-body hash) and final signature, not just the
    /// key derivation. The signer's signed-header set (host;x-amz-date) matches this vector exactly.
    @Test func getVanillaSignatureMatchesAWSVector() throws {
        let url = try #require(URL(string: "https://example.amazonaws.com/"))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let credentials = BedrockCredentials(
            accessKey: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
        )
        let date = try fixedUTCDate(year: 2015, month: 8, day: 30, hour: 12, minute: 36)
        SigV4.sign(&request, body: Data(), credentials: credentials, region: "us-east-1", service: "service", date: date)
        #expect(request.value(forHTTPHeaderField: "Authorization")
            == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
            + "SignedHeaders=host;x-amz-date, "
            + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func endpointPercentEncodesModelID() throws {
        let url = try #require(BedrockTurnSession.endpoint(
            region: "us-east-1", model: "anthropic.claude-3-5-sonnet-20240620-v1:0"
        ))
        #expect(url.absoluteString == "https://bedrock-runtime.us-east-1.amazonaws.com/model/"
            + "anthropic.claude-3-5-sonnet-20240620-v1%3A0/invoke-with-response-stream")
    }

    @Test func inferenceProfileModelIDFormsEndpoint() throws {
        let url = try #require(BedrockTurnSession.endpoint(region: "us-west-2", model: "us.anthropic.claude-opus-4-8"))
        #expect(url.absoluteString
            == "https://bedrock-runtime.us-west-2.amazonaws.com/model/us.anthropic.claude-opus-4-8/invoke-with-response-stream")
    }

    // MARK: - Event-stream framing

    @Test func frameUnwrapsToAnthropicEvent() {
        let inner = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
        var parser = BedrockEventStreamParser()
        let (events, errors) = parser.ingest(frame(wrapping: inner))
        #expect(errors.isEmpty)
        #expect(events.count == 1)
        let decoder = AnthropicDecoder()
        let pieces = decoder.ingest(eventData: events[0])
        #expect(pieces.contains { if case .text("Hi") = $0 { true } else { false } })
    }

    @Test func framesReassembleAcrossChunkBoundaries() {
        let full = frame(wrapping: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}"#)
        var parser = BedrockEventStreamParser()
        let half = full.count / 2
        #expect(parser.ingest(full.prefix(half)).events.isEmpty) // incomplete frame, nothing yet
        let (events, _) = parser.ingest(full.suffix(from: full.startIndex + half))
        #expect(events.count == 1)
    }

    @Test func exceptionFrameSurfacesAsError() {
        // A non-`chunk` frame (e.g. modelStreamErrorException): the payload is raw JSON with no
        // `bytes` field, so the parser reports it as an error instead of an event.
        var parser = BedrockEventStreamParser()
        let (events, errors) = parser.ingest(framePayload(Data(#"{"message":"throttled"}"#.utf8)))
        #expect(events.isEmpty)
        #expect(errors.count == 1)
        #expect(errors.first?.contains("throttled") == true)
    }

    // MARK: - nextTurn end-to-end

    @Test func nextTurnStreamsTextFromEventStream() async throws {
        let frames = [
            frame(wrapping: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#),
            frame(wrapping: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#)
        ]
        let model = BedrockChatModel(
            region: "us-east-1", model: "anthropic.claude",
            auth: .sigV4(BedrockCredentials(accessKey: "AK", secretKey: "SK")),
            transport: StubBedrockTransport(status: 200, chunks: frames)
        )
        let collector = TextSink()
        let message = try await model.makeSession().nextTurn(
            messages: [.human("hi")], systemPrompt: nil, tools: []
        ) { if case .text(let token) = $0 { collector.append(token) } }

        #expect(message.text == "Hello")
        #expect(collector.text == "Hello")
    }

    @Test func nextTurnThrowsOnErrorStatus() async throws {
        let model = BedrockChatModel(
            region: "us-east-1", model: "anthropic.claude",
            auth: .sigV4(BedrockCredentials(accessKey: "AK", secretKey: "SK")),
            transport: StubBedrockTransport(status: 403, chunks: [Data("{\"message\":\"denied\"}".utf8)])
        )
        await #expect(throws: BedrockModelError.self) {
            _ = try await model.makeSession().nextTurn(
                messages: [.human("hi")], systemPrompt: nil, tools: []
            ) { _ in }
        }
    }

    @Test func nextTurnThrowsOnExceptionFrame() async throws {
        let model = BedrockChatModel(
            region: "us-east-1", model: "anthropic.claude",
            auth: .sigV4(BedrockCredentials(accessKey: "AK", secretKey: "SK")),
            transport: StubBedrockTransport(
                status: 200, chunks: [framePayload(Data(#"{"message":"throttled"}"#.utf8))]
            )
        )
        await #expect(throws: BedrockModelError.self) {
            _ = try await model.makeSession().nextTurn(
                messages: [.human("hi")], systemPrompt: nil, tools: []
            ) { _ in }
        }
    }

    @Test func nextTurnThrowsOnAnthropicErrorEventInFrame() async throws {
        let errorEvent = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        let model = BedrockChatModel(
            region: "us-east-1", model: "anthropic.claude",
            auth: .sigV4(BedrockCredentials(accessKey: "AK", secretKey: "SK")),
            transport: StubBedrockTransport(status: 200, chunks: [frame(wrapping: errorEvent)])
        )
        await #expect(throws: BedrockModelError.self) {
            _ = try await model.makeSession().nextTurn(
                messages: [.human("hi")], systemPrompt: nil, tools: []
            ) { _ in }
        }
    }

    // MARK: - Bearer-token auth

    @Test func resolvePrefersExplicitBearerToken() {
        // An explicit token short-circuits before any environment lookup, so this is env-independent.
        #expect(BedrockAuth.resolve(bearerToken: "explicit") == .bearerToken("explicit"))
    }

    @Test func endpointUsesVerbatimBaseURLWhenProvided() throws {
        let url = try #require(BedrockTurnSession.endpoint(
            baseURL: "https://my-gateway.example.com/", region: "us-east-1",
            model: "us.anthropic.claude-opus-4-8"
        ))
        // Trailing slash trimmed; the region is ignored when an explicit baseURL is supplied.
        #expect(url.absoluteString == "https://my-gateway.example.com/model/"
            + "us.anthropic.claude-opus-4-8/invoke-with-response-stream")
    }

    @Test func bearerTokenAuthSetsAuthorizationHeaderAndSkipsSigV4() async throws {
        let frames = [frame(wrapping:
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#)]
        let transport = CapturingBedrockTransport(status: 200, chunks: frames)
        let model = BedrockChatModel(
            region: "us-east-1", model: "us.anthropic.claude-opus-4-8",
            auth: .bearerToken("secret-token"),
            baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com", transport: transport
        )
        _ = try await model.makeSession().nextTurn(
            messages: [.human("hi")], systemPrompt: nil, tools: []
        ) { _ in }

        let request = try #require(transport.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == nil) // bearer auth skips SigV4
        #expect(request.url?.absoluteString == "https://bedrock-runtime.us-east-1.amazonaws.com/model/"
            + "us.anthropic.claude-opus-4-8/invoke-with-response-stream")
    }

    // MARK: - Helpers

    /// Wrap `eventJSON` as a `chunk` frame whose payload is `{"bytes": base64}`.
    private func frame(wrapping eventJSON: String) -> Data {
        let base64 = Data(eventJSON.utf8).base64EncodedString()
        return framePayload(Data(("{\"bytes\":\"" + base64 + "\"}").utf8))
    }

    /// Frame an arbitrary payload as one AWS event-stream message: empty headers, zeroed CRCs (the
    /// parser doesn't verify them). Used for both `chunk` frames and exception frames.
    private func framePayload(_ payload: Data) -> Data {
        func be(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        var data = Data()
        data.append(be(UInt32(16 + payload.count))) // total length
        data.append(be(0)) // headers length
        data.append(be(0)) // prelude CRC (ignored)
        data.append(payload)
        data.append(be(0)) // message CRC (ignored)
        return data
    }

    /// A fixed UTC `Date` for deterministic SigV4 signing.
    private func fixedUTCDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        return try #require(calendar.date(from: components))
    }
}

/// A transport that replays canned `Data` chunks (frame bytes), so `nextTurn` runs without a network.
private struct StubBedrockTransport: BedrockStreamingTransport {
    let status: Int
    let chunks: [Data]

    func send(
        _: URLRequest
    ) async throws -> (status: Int, bytes: AsyncThrowingStream<Data, Error>) {
        let captured = chunks
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in captured { continuation.yield(chunk) }
            continuation.finish()
        }
        return (status, stream)
    }
}

/// Captures the request passed to `send` (so a test can assert on its headers/URL), then replays the
/// canned frame `Data`, like ``StubBedrockTransport``.
private final class CapturingBedrockTransport: BedrockStreamingTransport, @unchecked Sendable {
    let status: Int
    let chunks: [Data]
    private let lock = NSLock()
    private var capturedRequest: URLRequest?

    init(status: Int, chunks: [Data]) {
        self.status = status
        self.chunks = chunks
    }

    var lastRequest: URLRequest? { lock.withLock { capturedRequest } }

    func send(
        _ request: URLRequest
    ) async throws -> (status: Int, bytes: AsyncThrowingStream<Data, Error>) {
        lock.withLock { capturedRequest = request }
        let frames = chunks
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for frame in frames { continuation.yield(frame) }
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
