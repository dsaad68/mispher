import Foundation

/// The injectable transport `OpenAITurnSession` streams a chat-completions response through.
/// Abstracted as a protocol so tests feed canned Server-Sent-Events lines without a network;
/// the live implementation (`URLSessionStreamingTransport`) streams `URLSession.bytes(for:)`.
public protocol OpenAIStreamingTransport: Sendable {
    /// Send `request` and return the HTTP status plus an async stream of the response's raw
    /// lines (one element per `\n`-delimited line, SSE `data:` lines included). A non-2xx
    /// status streams the error body so the caller can surface it.
    func send(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>)
}

/// The live transport: a `URLSession` wrapper that streams the response body line by line.
/// Uses a generous resource timeout so a long generation isn't cut off, while the per-request
/// timeout still guards a stalled connection (it resets as bytes arrive).
public struct URLSessionStreamingTransport: OpenAIStreamingTransport {
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
    ) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
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
