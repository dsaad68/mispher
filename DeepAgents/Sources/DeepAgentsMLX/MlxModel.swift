import DeepAgents
import Foundation
import MLXLMCommon

/// One on-device MLX model the user can run via `mlx-swift-lm`. Identified by its
/// Hugging Face repo id (downloaded on demand by the package). The catalog is the
/// LiquidAI LFM2.5 family — language (instruct) and vision (VL) — and is trivially
/// extensible: add a row here and it shows up in Settings ▸ Local models.
public struct MlxModel: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable { case language, vision }

    /// Hugging Face repo id, e.g. "LiquidAI/LFM2.5-1.2B-Instruct-MLX-8bit".
    public let id: String
    public let displayName: String
    /// Short descriptor for the row, e.g. "Instruct · 8-bit".
    public let detail: String
    public let kind: Kind
    /// Rough on-disk / resident size, for the row's size hint and a "large" warning.
    public let approxGB: Double

    public var isVision: Bool { kind == .vision }

    /// Liquid's recommended sampling for this model when driving the on-device ReAct agent,
    /// per model card / docs: 8B-A1B is temperature 0.2 / top-k 80; the 1.2B instruct
    /// models are temperature 0.1 / top-k 50 (more deterministic — they follow tool
    /// instructions more reliably); Thinking additionally wants top-p 0.1. All text models
    /// take repetition penalty 1.05. Generous `maxTokens` so reasoning + the tool loop
    /// aren't truncated.
    ///
    /// VLMs run *without* a repetition penalty to dodge a crash in mlx-swift-lm: the penalty
    /// ring buffer (`TokenRing.loadPrompt`) reads `prompt.dim(0)` as the token count, but the
    /// LFM2-VL processor returns a 2-D `(1, seqLen)` prompt, so the batch dim (1) is mistaken
    /// for the length. The ring is then sized to `seqLen + 19` instead of 20, and the first
    /// sampled token dies in `MLX.where` with "Shapes (20) and (seqLen+19) cannot be
    /// broadcast". Text models return a 1-D prompt and are unaffected, so they keep the
    /// penalty. Drop this special case once the upstream bug is fixed.
    public var agentParameters: GenerateParameters {
        if isVision {
            return .init(maxTokens: 4096, temperature: 0.1, topK: 50)
        }
        if id.contains("8B-A1B") {
            return .init(maxTokens: 4096, temperature: 0.2, topK: 80, repetitionPenalty: 1.05)
        }
        if id.contains("Thinking") {
            // Reasoning models spend tokens on a <think> pass before answering, so give the
            // generation + tool loop extra headroom to avoid truncating mid-reasoning.
            // Liquid's Thinking recommendation adds top_p 0.1 on top of the instruct params;
            // without it the reasoning pass meanders and tool calls come out malformed.
            return .init(
                maxTokens: 8192, temperature: 0.1, topP: 0.1, topK: 50, repetitionPenalty: 1.05
            )
        }
        return .init(maxTokens: 4096, temperature: 0.1, topK: 50, repetitionPenalty: 1.05)
    }

    /// The model's context window in tokens — what summarization's 85% trigger and the context
    /// meter measure against. The whole LFM2.5 family ships a 32k window (matching the on-device
    /// budget the ReAct loop already assumes), so this is a constant today; switch to per-id logic
    /// if a model with a different window is added to the catalog.
    public var contextWindowTokens: Int { 32768 }

    public var sizeLabel: String {
        approxGB >= 1 ? String(format: "%.1f GB", approxGB) : String(format: "%.0f MB", approxGB * 1024)
    }

    /// Compact name for tight chrome (header pills), e.g. "1.2B Instruct".
    public var shortName: String {
        displayName
            .replacingOccurrences(of: "LFM2.5 ", with: "")
            .replacingOccurrences(of: "LFM2.5-", with: "")
    }

    public static let catalog: [MlxModel] = [
        MlxModel(id: "LiquidAI/LFM2.5-350M-MLX-8bit",
                 displayName: "LFM2.5 350M", detail: "Instruct · 8-bit", kind: .language, approxGB: 0.4),
        MlxModel(id: "LiquidAI/LFM2.5-1.2B-Instruct-MLX-8bit",
                 displayName: "LFM2.5 1.2B Instruct", detail: "Instruct · 8-bit", kind: .language, approxGB: 1.3),
        MlxModel(id: "LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16",
                 displayName: "LFM2.5 1.2B Instruct", detail: "Instruct · bf16", kind: .language, approxGB: 2.5),
        MlxModel(id: "LiquidAI/LFM2.5-1.2B-Thinking-MLX-8bit",
                 displayName: "LFM2.5 1.2B Thinking", detail: "Thinking · 8-bit", kind: .language, approxGB: 1.3),
        MlxModel(id: "LiquidAI/LFM2.5-1.2B-Thinking-MLX-bf16",
                 displayName: "LFM2.5 1.2B Thinking", detail: "Thinking · bf16", kind: .language, approxGB: 2.4),
        MlxModel(id: "LiquidAI/LFM2.5-8B-A1B-MLX-8bit",
                 displayName: "LFM2.5 8B-A1B", detail: "MoE · 8-bit · large", kind: .language, approxGB: 9.0),
        MlxModel(id: "LiquidAI/LFM2.5-VL-450M-MLX-8bit",
                 displayName: "LFM2.5-VL 450M", detail: "Vision · 8-bit", kind: .vision, approxGB: 0.6),
        MlxModel(id: "LiquidAI/LFM2.5-VL-450M-MLX-bf16",
                 displayName: "LFM2.5-VL 450M", detail: "Vision · bf16", kind: .vision, approxGB: 1.0),
        MlxModel(id: "mlx-community/LFM2.5-VL-1.6B-8bit",
                 displayName: "LFM2.5-VL 1.6B", detail: "Vision · 8-bit", kind: .vision, approxGB: 2.1)
    ]

    /// Text (instruct) models only — used by the Translate model picker (translation runs
    /// on a language model, never a VLM).
    public static var languageCatalog: [MlxModel] { catalog.filter { !$0.isVision } }
}
