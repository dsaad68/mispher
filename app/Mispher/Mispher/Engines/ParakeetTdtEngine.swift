import AVFoundation
import CoreML
import FluidAudio

/// Batch backend for Parakeet TDT v3 (25 European languages) via FluidAudio's
/// `AsrManager`. Wrapped by `BatchReprocessEngine` to produce live partials.
actor ParakeetTdtBackend: BatchTranscriber {
    private var manager: AsrManager?

    func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        if manager != nil { return }

        status("Loading Parakeet TDT v3…")
        let models = try await AsrModels.downloadAndLoad(
            version: .v3,
            encoderPrecision: .int8
        ) { progress in
            status("Downloading model… \(Int(progress.fractionCompleted * 100))%")
        }

        let manager = AsrManager(config: .default, models: models)
        self.manager = manager
        status("Model ready (ANE)")
    }

    func transcribe(samples: [Float], sourceRate: Double) async throws -> String {
        guard let manager else { return "" }
        guard let buffer = AudioBuffers.make(AudioSamples(samples: samples, sampleRate: sourceRate))
        else { return "" }

        // Fresh decoder state per pass — we always re-transcribe the whole buffer.
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(buffer, decoderState: &state, language: nil)
        return result.text
    }
}
