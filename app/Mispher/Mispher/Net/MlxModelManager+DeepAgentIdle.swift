import DeepAgents
import DeepAgentsMLX
import Foundation

/// The on-device deep agent's model residency, split out of ``MlxModelManager`` to keep that file in
/// budget. The deep agent's planner + vision models are *time-managed* - warmed when the DeepAgent is
/// selected and freed after an idle timeout - rather than pinned resident under the `.ask` owner, and
/// the vision model loads lazily on first use. See ``LazyChatModel`` and ``MlxModelManager/deepReactAgent``.
extension MlxModelManager {
    var isDeepAgentSelected: Bool {
        currentAskId.flatMap { DeepAgentVariant.variant(for: $0) } != nil
    }

    /// Apply the user's Ask-tab settings. When the deep agent is the current Ask selection, free a
    /// planner/vision that's no longer used and re-warm the new planner (the vision reloads lazily on
    /// next use); a changed idle timeout is reflected on the warm planner immediately.
    public func setDeepAgentConfig(
        planner: String, vision: String, plannerIdleMinutes: Int, visionIdleMinutes: Int
    ) {
        let oldPlanner = deepAgentPlannerID
        let oldVision = deepAgentVisionID
        deepAgentPlannerID = planner
        deepAgentVisionID = vision
        self.plannerIdleMinutes = plannerIdleMinutes
        self.visionIdleMinutes = visionIdleMinutes
        guard isDeepAgentSelected else { return }
        if oldPlanner != planner {
            coolIdle(oldPlanner)
            prewarmIdle(planner, idleMinutes: plannerIdleMinutes)
        } else {
            scheduleIdle(planner, idleMinutes: plannerIdleMinutes) // refresh the timer with new minutes
        }
        if oldVision != vision { coolIdle(oldVision) }
    }

    /// Resolve `id` for an in-flight deep-agent turn: load it if needed, cancel its idle unload, and mark
    /// it in active use so the idle timer can't free it mid-round. Returns nil if it isn't in the catalog
    /// or fails to load. The ``LazyChatModel`` `begin` closure; pair with ``endUse(_:idleMinutes:)``.
    func beginUse(_ id: String) async -> MlxChatModel? {
        idleTimers[id]?.cancel()
        idleTimers[id] = nil
        activeUses[id, default: 0] += 1
        guard let model = MlxModel.catalog.first(where: { $0.id == id }) else {
            endActiveUse(id)
            return nil
        }
        load(model)
        await loadTasks[id]?.value
        guard let container = containers[id] else {
            endActiveUse(id)
            return nil
        }
        return MlxChatModel(
            container: container, supportsVision: model.isVision, modelID: model.id,
            contextWindowTokens: model.contextWindowTokens, generateParameters: model.agentParameters
        )
    }

    /// Release one deep-agent turn's claim on `id`; when the last finishes, (re)arm the idle unload after
    /// `idleMinutes` (<= 0 keeps it resident). The ``LazyChatModel`` `end` closure.
    func endUse(_ id: String, idleMinutes: Int) {
        endActiveUse(id)
        scheduleIdle(id, idleMinutes: idleMinutes)
    }

    private func endActiveUse(_ id: String) {
        if let count = activeUses[id] { activeUses[id] = max(0, count - 1) }
    }

    /// Load `id` now and arm its idle unload (pre-warm on selection), without marking it in active use.
    /// The idle timer is armed only once the load settles, so a short idle timeout can't cancel an
    /// in-flight load (which would defeat warm-on-selection); the timer never fires for a load that
    /// failed or was cancelled (no resident container to free).
    func prewarmIdle(_ id: String, idleMinutes: Int) {
        guard let model = MlxModel.catalog.first(where: { $0.id == id }) else {
            scheduleIdle(id, idleMinutes: idleMinutes)
            return
        }
        load(model)
        Task { [weak self] in
            await self?.loadTasks[id]?.value
            guard self?.containers[id] != nil else { return }
            self?.scheduleIdle(id, idleMinutes: idleMinutes)
        }
    }

    /// (Re)arm `id`'s idle unload. No-op while it's in active use or when `idleMinutes <= 0` (resident).
    private func scheduleIdle(_ id: String, idleMinutes: Int) {
        idleTimers[id]?.cancel()
        idleTimers[id] = nil
        guard activeUses[id, default: 0] == 0, idleMinutes > 0 else { return }
        let seconds = Double(idleMinutes) * 60
        idleTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.idleUnload(id)
        }
    }

    /// Cancel `id`'s idle timer and unload it now, unless an active turn or another owner still needs it.
    /// Used when the deep agent is deselected or its planner/vision selection changes.
    func coolIdle(_ id: String) {
        idleTimers[id]?.cancel()
        idleTimers[id] = nil
        unloadIfUnclaimed(id)
    }

    private func idleUnload(_ id: String) {
        idleTimers[id] = nil
        unloadIfUnclaimed(id)
    }

    /// Unload `id` only when nothing else needs it: no in-flight turn, and no other owner (a manual
    /// "on" toggle, translation, cleanup, …) pinning it resident.
    private func unloadIfUnclaimed(_ id: String) {
        guard activeUses[id, default: 0] == 0, owners[id]?.isEmpty ?? true else { return }
        if let model = MlxModel.catalog.first(where: { $0.id == id }) { unload(model) }
    }
}
