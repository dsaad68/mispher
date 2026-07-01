import DeepAgents
import DeepAgentsMLX
import SwiftUI

/// The "Ask" settings tab: choose the on-device DeepAgent's planner and vision models, and how long
/// each may sit idle before it's unloaded from memory. The DeepAgent is turned on from the HUD Ask
/// picker; this tab is its one-time model + memory configuration (see ``TranscriptionViewModel`` /
/// ``MlxModelManager/setDeepAgentConfig(planner:vision:plannerIdleMinutes:visionIdleMinutes:)``).
struct AskSettingsView: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            modelsSection
            idleSection
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "DeepAgent models")
            DeepAgentModelPickers()
        }
    }

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Idle unload")
            SettingsCard {
                SettingsRow(
                    title: "Planner idle timeout",
                    subtitle: "Unload the planner after this many minutes with no activity, freeing its "
                        + "memory. It reloads on the next request. 0 keeps it loaded."
                ) {
                    idleField(current: vm.deepAgent.plannerIdleMinutes, set: { vm.deepAgent.plannerIdleMinutes = $0 })
                }
                // The vision idle timeout is moot when vision is set to None (no vision model to unload).
                if !vm.deepAgent.visionModelId.isEmpty {
                    Hairline()
                    SettingsRow(
                        title: "Vision idle timeout",
                        subtitle: "Unload the vision model after this many idle minutes. It reloads the next "
                            + "time the planner looks at the screen. 0 keeps it loaded."
                    ) {
                        idleField(current: vm.deepAgent.visionIdleMinutes, set: { vm.deepAgent.visionIdleMinutes = $0 })
                    }
                }
            }
        }
    }

    /// A small numeric minutes field (0 = keep resident), bound through an explicit getter/setter so it
    /// reads/writes the `@Observable` view model directly.
    private func idleField(current: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(get: { current }, set: { set(max(0, $0)) }), format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 44)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 0.75)
                )
            Text("min")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.fg2)
        }
    }
}

/// Planner + vision model pickers for the on-device DeepAgent, shared by the Ask settings tab and
/// onboarding. The vision model can be "None" (an empty id): the planner then runs blind, with no
/// vision subagent and no screen capture (see ``MispherDeepAgent/make`` / ``MlxModelManager/deepReactAgent``).
struct DeepAgentModelPickers: View {
    @Environment(TranscriptionViewModel.self) private var vm

    private var languageModels: [MlxModel] { MlxModel.languageCatalog }
    private var visionModels: [MlxModel] { MlxModel.catalog.filter(\.isVision) }

    var body: some View {
        SettingsCard {
            SettingsRow(
                title: "Planner model",
                subtitle: "The local language model that plans the task and delegates subtasks."
            ) {
                modelDropdown(
                    options: languageModels, current: vm.deepAgent.plannerModelId,
                    select: { vm.deepAgent.plannerModelId = $0 }
                )
            }
            Hairline()
            SettingsRow(
                title: "Vision model",
                subtitle: "The vision model the vision subagent runs, or None to run the planner blind. "
                    + "Loads only when the planner needs to look at the screen."
            ) {
                modelDropdown(
                    options: visionModels, current: vm.deepAgent.visionModelId,
                    noneLabel: "None", select: { vm.deepAgent.visionModelId = $0 }
                )
            }
        }
    }

    /// A glass dropdown over `options` (language or vision models), mirroring the dictation/rewrite
    /// model rows: the pill shows the compact short name while the menu lists full "name · detail" rows.
    /// When `noneLabel` is given, a leading entry with an empty id is offered (vision "None"); the pill
    /// reads `noneLabel` while that empty id is selected.
    private func modelDropdown(
        options: [MlxModel], current: String, noneLabel: String? = nil, select: @escaping (String) -> Void
    ) -> some View {
        var rows = options.map { (value: $0.id, label: "\($0.displayName) · \($0.detail)") }
        if let noneLabel { rows.insert((value: "", label: noneLabel), at: 0) }
        let display = current.isEmpty
            ? (noneLabel ?? "Select…")
            : (options.first { $0.id == current }?.shortName ?? "Select…")
        return VStack(alignment: .center, spacing: 5) {
            GlassDropdown(
                options: rows,
                selection: Binding(get: { current }, set: { select($0) }),
                maxWidth: 220,
                displayLabel: display
            )
            ModelMemoryHint(modelId: current)
        }
    }
}
