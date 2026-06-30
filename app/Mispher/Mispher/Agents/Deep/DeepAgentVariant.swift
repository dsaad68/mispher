import DeepAgents
import Foundation

/// The on-device DeepAgent entry offered in the Ask picker. Its `id` is a sentinel Ask selection — NOT
/// a Hugging Face catalog id — that `MlxModelManager` recognizes to build the deep agent. The actual
/// planner (text) and vision (VLM) models, and their idle timeouts, are chosen by the user in the Ask
/// settings tab and held by `MlxModelManager`; this type is just the picker entry + sentinel.
public struct DeepAgentVariant: Identifiable, Sendable, Hashable {
    /// Sentinel Ask-selection id (persisted as `askModelId`); never a catalog model id.
    public let id: String
    /// Short label for the pill / status.
    public let label: String
    /// Picker subtitle.
    public let detail: String

    /// The single sentinel id selecting the on-device deep agent.
    public static let deepAgentID = "mispher.deepagent"

    /// Defaults used until the user picks their own in the Ask settings tab. Vision defaults to none
    /// (an empty id runs the planner blind); the user can enable a VLM in the Ask settings tab.
    public static let defaultPlannerID = "LiquidAI/LFM2.5-8B-A1B-MLX-8bit"
    public static let defaultVisionID = ""
    public static let defaultIdleMinutes = 10

    /// The on-device DeepAgent entry (its planner + vision come from the user's Ask settings).
    public static let all: [DeepAgentVariant] = [
        DeepAgentVariant(id: deepAgentID, label: "DeepAgent", detail: "on-device planner + vision")
    ]

    /// The variant for a sentinel selection id, or nil if `id` is an ordinary model selection.
    public static func variant(for id: String) -> DeepAgentVariant? {
        all.first { $0.id == id }
    }
}
