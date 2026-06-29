import Foundation

/// The injectable transport ``BedrockTurnSession`` reads the event-stream response through. Unlike
/// the SSE transports, Bedrock frames are binary (not `\n`-delimited), so this yields raw `Data`
/// chunks; ``BedrockEventStreamParser`` reassembles frames across whatever boundaries arrive.
/// Abstracted as a protocol so tests feed canned frame bytes without a network.
public protocol BedrockStreamingTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, bytes: AsyncThrowingStream<Data, Error>)
}

/// The live transport: streams `URLSession.bytes(for:)` as `Data` chunks. Same generous timeouts as
/// the SSE transports (a long generation isn't cut off; a stalled connection still trips).
public struct URLSessionBedrockTransport: BedrockStreamingTransport {
    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 3600
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(
        _ request: URLRequest
    ) async throws -> (status: Int, bytes: AsyncThrowingStream<Data, Error>) {
        let (byteStream, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    for try await byte in byteStream { continuation.yield(Data([byte])) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, stream)
    }
}
