import DeepAgentsMLX
import Foundation

/// Catalog lookups for the per-feature model selections. Pure computed properties split out of
/// ``TranscriptionViewModel`` so the main file stays within the length limit.
@MainActor
extension TranscriptionViewModel {
    /// Human label for the current Ask selection: the DeepAgent's label when Ask is on, or nil when
    /// off. Ask is DeepAgent-only, so this is "DeepAgent" whenever enabled.
    var askSelectionLabel: String? {
        askModelId.flatMap { DeepAgentVariant.variant(for: $0)?.label }
    }

    /// The DeepAgent planner model's short name (e.g. "8B-A1B"), or "Default" when its id isn't in the
    /// catalog. Used for the onboarding summary.
    var askPlannerShortName: String {
        MlxModel.catalog.first { $0.id == deepAgent.plannerModelId }?.shortName ?? "Default"
    }

    /// The DeepAgent vision model's short name, or nil when vision is set to None (an empty id) or its
    /// id isn't in the catalog. Used for the onboarding summary.
    var askVisionShortName: String? {
        deepAgent.visionModelId.isEmpty ? nil : MlxModel.catalog.first { $0.id == deepAgent.visionModelId }?.shortName
    }

    /// The catalog entry for the selected translation model, if any.
    var translationModel: MlxModel? {
        MlxModel.catalog.first { $0.id == translationModelId }
    }

    /// The catalog entry for the selected dictation-cleanup model, if any.
    var cleanupModel: MlxModel? { MlxModel.catalog.first { $0.id == cleanupModelId } }

    /// The catalog entry for the selected voice-rewrite model, if any.
    var rewriteModel: MlxModel? { MlxModel.catalog.first { $0.id == rewriteModelId } }
}
