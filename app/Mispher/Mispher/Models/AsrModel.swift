import DeepAgentsMLX
import Foundation

/// A selectable transcription model. Most are on-device FluidAudio CoreML
/// bundles the user downloads; Qwen is reached over HTTP via a local
/// `llama-server`. The user picks one from the header dropdown (only downloaded
/// models are activatable) and manages downloads in Settings.
enum AsrModel: String, CaseIterable, Identifiable, Sendable {
    /// Parakeet realtime EOU 120M — native ANE streaming, English. (Current default.)
    case parakeetEouEnglish
    /// Nemotron 3.5 Streaming Multilingual 0.6B — native ANE streaming, ~40 languages.
    case nemotronMultilingual
    /// Parakeet TDT v3 — batch, 25 European languages.
    case parakeetTdtV3
    /// Parakeet CTC — batch, Mandarin Chinese, int8 encoder (smaller, ANE).
    case parakeetCtcInt8
    /// Parakeet CTC — batch, Mandarin Chinese, fp32 encoder (higher precision).
    case parakeetCtcFp32
    /// Qwen3-ASR via local llama-server (HTTP), Chinese.
    case qwenChinese

    var id: String { rawValue }

    /// For the two CTC rows, which encoder precision this case runs (nil for non-CTC).
    var ctcUseInt8: Bool? {
        switch self {
        case .parakeetCtcInt8: return true
        case .parakeetCtcFp32: return false
        default: return nil
        }
    }

    /// Rows that share one on-disk download. The CTC int8/fp32 variants come from a single
    /// FluidAudio bundle (both encoders), so downloading or deleting one affects both.
    var downloadSiblings: [AsrModel] {
        switch self {
        case .parakeetCtcInt8, .parakeetCtcFp32: return [.parakeetCtcInt8, .parakeetCtcFp32]
        default: return [self]
        }
    }

    /// Full name shown in the dropdown and Settings rows.
    var displayName: String {
        switch self {
        case .parakeetEouEnglish: return "Parakeet EOU"
        case .nemotronMultilingual: return "Nemotron Multilingual"
        case .parakeetTdtV3: return "Parakeet TDT v3"
        case .parakeetCtcInt8: return "Parakeet CTC 中文 · int8"
        case .parakeetCtcFp32: return "Parakeet CTC 中文 · fp32"
        case .qwenChinese: return "Qwen3-ASR"
        }
    }

    /// Compact name shown on the header pill.
    var shortName: String {
        switch self {
        case .parakeetEouEnglish: return "Parakeet EOU"
        case .nemotronMultilingual: return "Nemotron"
        case .parakeetTdtV3: return "Parakeet v3"
        case .parakeetCtcInt8: return "CTC int8"
        case .parakeetCtcFp32: return "CTC fp32"
        case .qwenChinese: return "Qwen"
        }
    }

    /// One-line descriptor for the Settings rows.
    var subtitle: String {
        switch self {
        case .parakeetEouEnglish: return "Streaming · English · ~0.5 GB"
        case .nemotronMultilingual: return "Streaming · 40 languages · ~1.1 GB"
        case .parakeetTdtV3: return "Batch · 25 European langs · ~1.1 GB"
        case .parakeetCtcInt8: return "Batch · Mandarin 中文 · int8 · ~1.1 GB"
        case .parakeetCtcFp32: return "Batch · Mandarin 中文 · fp32 · ~1.1 GB"
        case .qwenChinese: return "Server · Chinese · llama-server"
        }
    }

    /// True streaming (token-by-token) vs. batch re-transcription.
    var isStreaming: Bool {
        switch self {
        case .parakeetEouEnglish, .nemotronMultilingual: return true
        case .parakeetTdtV3, .parakeetCtcInt8, .parakeetCtcFp32, .qwenChinese: return false
        }
    }

    /// Qwen needs a running local `llama-server` rather than a downloadable bundle.
    var requiresLocalServer: Bool { self == .qwenChinese }

    /// Whether this is a downloadable FluidAudio model bundle (everything but Qwen).
    var isDownloadable: Bool { !requiresLocalServer }

    /// Status line shown once the engine is prepared and ready to record.
    var readyMessage: String {
        switch self {
        case .qwenChinese:
            return "Ready — Qwen server reachable. Press Space to talk."
        default:
            return "Ready — \(displayName). Press Space to talk."
        }
    }
}
