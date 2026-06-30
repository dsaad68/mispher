import Foundation

/// A batch transcription backend wrapped by `BatchReprocessEngine`. Implementations
/// own a FluidAudio batch manager (Parakeet TDT v3, Parakeet CTC zh-CN) and turn a
/// snapshot of accumulated audio into text. Backends are actors, hence `Sendable`.
protocol BatchTranscriber: Sendable {
    /// Download/load the model. `status` reports progress to the UI.
    func prepare(status: @escaping @Sendable (String) -> Void) async throws
    /// Transcribe an entire utterance snapshot (mono float at `sourceRate`).
    func transcribe(samples: [Float], sourceRate: Double) async throws -> String
}

/// Gives batch models a live-ish feel by periodically re-transcribing the *entire*
/// accumulated utterance — the same strategy the Qwen engine uses. Re-running the
/// whole buffer avoids chunk-boundary word splitting; a single in-flight pass at a
/// time yields natural skip-on-backlog. Best for short push-to-talk clips.
actor BatchReprocessEngine<Backend: BatchTranscriber>: TranscriptionEngine {
    private let backend: Backend
    /// Seconds of *new* audio to accumulate before kicking off another pass.
    private let refreshSeconds: Double

    private var partial: (@Sendable (String) -> Void)?
    private var buffer: [Float] = []
    private var sourceRate: Double = 16000
    private var accumulated = ""
    private var inFlight: Task<Void, Never>?
    private var lastKickCount = 0

    init(backend: Backend, refreshSeconds: Double = 1.4) {
        self.backend = backend
        self.refreshSeconds = refreshSeconds
    }

    func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        try await backend.prepare(status: status)
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

        let text = try await backend.transcribe(samples: buffer, sourceRate: sourceRate)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { accumulated = trimmed }
        return accumulated
    }

    // MARK: - Private

    private func kick() {
        let snapshot = buffer
        let rate = sourceRate
        let backend = backend
        let partial = partial
        lastKickCount = snapshot.count

        inFlight = Task { [weak self] in
            let text = try? await backend.transcribe(samples: snapshot, sourceRate: rate)
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
