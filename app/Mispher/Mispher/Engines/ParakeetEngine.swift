import AVFoundation
import CoreML
import FluidAudio

/// English engine: native CoreML/ANE streaming via FluidAudio's
/// `StreamingEouAsrManager` (Parakeet realtime EOU 120M).
///
/// The manager delivers the full accumulated transcript through the partial
/// callback after each chunk, so "live" text is just the latest callback value.
actor ParakeetEngine: TranscriptionEngine {
    private var manager: StreamingEouAsrManager?
    private var loaded = false

    func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        if loaded { return }

        status("Loading Parakeet model…")
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        config.allowLowPrecisionAccumulationOnGPU = true

        let manager = StreamingEouAsrManager(
            configuration: config,
            chunkSize: .ms160,
            eouDebounceMs: 1280
        )

        try await manager.loadModels(to: nil, configuration: nil) { progress in
            status("Downloading model… \(Int(progress.fractionCompleted * 100))%")
        }

        // Warm the ANE graph with a short burst of silence so the first real
        // utterance doesn't pay the cold-start latency.
        await manager.injectSilence(0.5)
        try? await manager.processBufferedAudio()
        await manager.reset()

        self.manager = manager
        loaded = true
        status("Model ready (ANE)")
    }

    func startSession(partial: @escaping @Sendable (String) -> Void) async throws {
        guard let manager else { throw AppError.modelLoadFailed("Parakeet not prepared") }
        await manager.reset()
        await manager.setPartialTranscriptCallback(partial)
    }

    func append(_ samples: AudioSamples) async {
        guard let manager, let buffer = Self.makeBuffer(samples) else { return }
        do {
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
        } catch {
            // Drop the occasional bad chunk rather than tearing down the session.
        }
    }

    func finishSession() async throws -> String {
        guard let manager else { return "" }
        let text = try await manager.finish()
        await manager.reset()
        return text
    }

    /// Rebuild a 1-channel float `AVAudioPCMBuffer` from a `Sendable` snapshot.
    /// FluidAudio resamples to 16 kHz internally, so the native rate is fine.
    private static func makeBuffer(_ samples: AudioSamples) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: samples.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.samples.count)
            )
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.samples.count)
        samples.samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.samples.count)
        }
        return buffer
    }
}
