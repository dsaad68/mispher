import Foundation

/// Chinese engine: Qwen3-ASR running in a local `llama-server`, reached over HTTP.
///
/// Qwen has no native streaming, so for a live feel we periodically re-transcribe
/// the *entire* accumulated utterance (Qwen is far faster than real-time, so a
/// few seconds of audio returns in well under a second). Re-transcribing the
/// whole buffer avoids chunk-boundary word splitting and duplication. A single
/// in-flight request at a time gives natural skip-on-backlog behavior.
actor QwenEngine: TranscriptionEngine {
    private let client: LlamaServerClient
    private var partial: (@Sendable (String) -> Void)?

    private var buffer: [Float] = [] // accumulated mono samples at source rate
    private var sourceRate: Double = 16000
    private var accumulated = ""
    private var inFlight: Task<Void, Never>?
    private var lastKickCount = 0

    /// Seconds of *new* audio to accumulate before kicking off another pass.
    private let refreshSeconds = 1.2

    init(baseURL: URL) {
        client = LlamaServerClient(baseURL: baseURL)
    }

    func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        status("Checking Qwen server…")
        guard await client.isReachable() else { throw AppError.serverUnreachable }
        status("Qwen server reachable (:\(client.port))")
    }

    func startSession(partial: @escaping @Sendable (String) -> Void) async throws {
        self.partial = partial
        buffer.removeAll()
        accumulated = ""
        lastKickCount = 0
        inFlight = nil
    }

    func append(_ samples: AudioSamples) async {
        sourceRate = samples.sampleRate
        buffer.append(contentsOf: samples.samples)

        let newSamples = buffer.count - lastKickCount
        if inFlight == nil && Double(newSamples) >= refreshSeconds * sourceRate {
            kick()
        }
    }

    func finishSession() async throws -> String {
        await inFlight?.value
        inFlight = nil
        guard !buffer.isEmpty else { return accumulated }

        let text = try await client.transcribe(samples: buffer, sourceRate: sourceRate)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { accumulated = trimmed }
        return accumulated
    }

    // MARK: - Private

    private func kick() {
        let snapshot = buffer
        let rate = sourceRate
        let client = client
        let partial = partial
        lastKickCount = snapshot.count

        inFlight = Task { [weak self] in
            let text = try? await client.transcribe(samples: snapshot, sourceRate: rate)
            await self?.applyResult(text, partial: partial)
        }
    }

    private func applyResult(_ text: String?, partial: (@Sendable (String) -> Void)?) {
        inFlight = nil
        if let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            accumulated = trimmed
            partial?(trimmed)
        }
    }
}
