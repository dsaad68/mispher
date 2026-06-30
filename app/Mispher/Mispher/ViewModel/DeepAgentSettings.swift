import DeepAgents
import DeepAgentsMLX
import Foundation
import Observation

/// User choices for the on-device DeepAgent (the Ask "DeepAgent" entry): which local models back the
/// planner and the vision subagent, and how long each may sit idle before it's unloaded from memory
/// (minutes; `0` keeps it resident). Persisted in `UserDefaults`; pushed to ``MlxModelManager`` on every
/// change (and when wired) so edits take effect live. Held by ``TranscriptionViewModel`` and edited in
/// the Ask settings tab.
@MainActor
@Observable
final class DeepAgentSettings {
    private static let plannerKey = "mispher.askPlannerModelId"
    private static let visionKey = "mispher.askVisionModelId"
    private static let plannerIdleKey = "mispher.askPlannerIdleMinutes"
    private static let visionIdleKey = "mispher.askVisionIdleMinutes"

    /// The model manager these settings drive. Set once by ``TranscriptionViewModel`` when it's wired;
    /// assigning it seeds the manager with the persisted choices.
    @ObservationIgnored weak var manager: MlxModelManager? {
        didSet { push() }
    }

    /// The local language model that plans the task and delegates subtasks.
    var plannerModelId: String = UserDefaults.standard.string(forKey: DeepAgentSettings.plannerKey)
        ?? DeepAgentVariant.defaultPlannerID {
        didSet { UserDefaults.standard.set(plannerModelId, forKey: Self.plannerKey); push() }
    }

    /// The vision (VLM) model the `vision` subagent runs; it loads lazily on first use.
    var visionModelId: String = UserDefaults.standard.string(forKey: DeepAgentSettings.visionKey)
        ?? DeepAgentVariant.defaultVisionID {
        didSet { UserDefaults.standard.set(visionModelId, forKey: Self.visionKey); push() }
    }

    /// Minutes the planner may sit idle before it's unloaded (`0` keeps it resident). Default 10.
    var plannerIdleMinutes: Int = DeepAgentSettings.loadIdle(DeepAgentSettings.plannerIdleKey) {
        didSet { UserDefaults.standard.set(plannerIdleMinutes, forKey: Self.plannerIdleKey); push() }
    }

    /// Minutes the vision model may sit idle before it's unloaded (`0` keeps it resident). Default 10.
    var visionIdleMinutes: Int = DeepAgentSettings.loadIdle(DeepAgentSettings.visionIdleKey) {
        didSet { UserDefaults.standard.set(visionIdleMinutes, forKey: Self.visionIdleKey); push() }
    }

    /// An idle-timeout setting, defaulting to 10 minutes when never set (so an unset key isn't read as
    /// `0` = "keep resident").
    private static func loadIdle(_ key: String) -> Int {
        UserDefaults.standard.object(forKey: key) == nil
            ? DeepAgentVariant.defaultIdleMinutes : UserDefaults.standard.integer(forKey: key)
    }

    /// Push the current model + idle-timeout choices to the model manager so live changes take effect.
    private func push() {
        manager?.setDeepAgentConfig(
            planner: plannerModelId, vision: visionModelId,
            plannerIdleMinutes: plannerIdleMinutes, visionIdleMinutes: visionIdleMinutes
        )
    }
}
