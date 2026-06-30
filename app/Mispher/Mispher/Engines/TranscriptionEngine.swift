import Foundation

/// Common interface for both transcription backends. Engines are actors so they
/// safely serialize their own state; the view model drives them with `await`.
///
/// Lifecycle: `prepare` (once, on selection / warmup) → `startSession` →
/// repeated `append` while recording → `finishSession` (returns final text).
protocol TranscriptionEngine: Actor {
    /// Download/warm models or verify the server. `status` reports progress to the UI.
    func prepare(status: @escaping @Sendable (String) -> Void) async throws

    /// Begin a recording session. `partial` is called with the growing live transcript.
    func startSession(partial: @escaping @Sendable (String) -> Void) async throws

    /// Feed one captured audio snapshot. Called in order from a single consumer loop.
    func append(_ samples: AudioSamples) async

    /// Stop, flush, and return the finalized transcript.
    func finishSession() async throws -> String
}
