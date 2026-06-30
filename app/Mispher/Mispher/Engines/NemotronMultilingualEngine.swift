import AVFoundation
import CoreML
import FluidAudio

/// Multilingual streaming engine: FluidAudio's `StreamingNemotronMultilingualAsrManager`
/// (Nemotron 3.5 Streaming Multilingual 0.6B) running on the Apple Neural Engine.
/// Covers ~40 languages; we run it in `"auto"` mode and let it detect the language.
///
/// Like the EOU manager, it delivers the full accumulated transcript through the
/// partial callback after each decoded chunk, so "live" text is just the latest
/// callback value.
actor NemotronMultilingualEngine: TranscriptionEngine {
    /// A user-selectable language hint for the multilingual model.
    struct Language: Identifiable, Sendable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// Curated subset of the model's ~40 supported locales. Unknown codes fall
    /// back to auto-detect inside `setLanguage`, so this list is safe to trim.
    static let supportedLanguages: [Language] = [
        .init(code: "auto", name: "Auto-detect"),
        .init(code: "en-US", name: "English"),
        .init(code: "zh-CN", name: "Chinese 中文"),
        .init(code: "ja-JP", name: "Japanese 日本語"),
        .init(code: "ko-KR", name: "Korean 한국어"),
        .init(code: "es-ES", name: "Spanish"),
        .init(code: "fr-FR", name: "French"),
        .init(code: "de-DE", name: "German"),
        .init(code: "it-IT", name: "Italian"),
        .init(code: "pt-BR", name: "Portuguese"),
        .init(code: "ru-RU", name: "Russian"),
        .init(code: "hi-IN", name: "Hindi"),
        .init(code: "vi-VN", name: "Vietnamese"),
        .init(code: "ar", name: "Arabic")
    ]

    /// Display name for a language code, falling back to the code itself.
    static func languageName(for code: String) -> String {
        supportedLanguages.first { $0.code == code }?.name ?? code
    }

    /// Variant used to pick which model build to download. `"auto"` and any
    /// non-Latin language (zh/ja/…) both route to the full-vocab `multilingual`
    /// build, so this stays fixed regardless of the runtime language hint.
    static let downloadLanguage = "auto"
    /// Processing-chunk tier (ms). 560 ms is the recommended low-latency build.
    static let chunkMs = 560

    /// Runtime language hint passed to `setLanguage` (e.g. "auto", "zh-CN").
    private let language: String
    private var manager: StreamingNemotronMultilingualAsrManager?

    init(language: String = "auto") {
        self.language = language
    }

    func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        if manager != nil { return }

        status("Loading Nemotron multilingual…")
        let directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: Self.downloadLanguage,
            chunkMs: Self.chunkMs
        ) { progress in
            status("Downloading model… \(Int(progress.fractionCompleted * 100))%")
        }

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: directory)
        await manager.setLanguage(language)

        self.manager = manager
        status("Model ready (ANE)")
    }

    func startSession(partial: @escaping @Sendable (String) -> Void) async throws {
        guard let manager else { throw AppError.modelLoadFailed("Nemotron not prepared") }
        await manager.reset()
        await manager.setLanguage(language)
        await manager.setPartialCallback(partial)
    }

    func append(_ samples: AudioSamples) async {
        guard let manager, let buffer = AudioBuffers.make(samples) else { return }
        do {
            _ = try await manager.process(audioBuffer: buffer)
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
}
