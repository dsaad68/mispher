import DeepAgents
import DeepAgentsMLX
import SwiftUI

/// Header indicator for the on-device DeepAgent that answers your speech (and backs the HUD chat).
/// Ask is DeepAgent-only, so there's no model to pick here: this is a static "DeepAgent" pill that
/// shows a spinner while its planner loads and opens the Ask settings tab when clicked (where the
/// planner and vision models live). Only shown when Ask is enabled; locked during a session.
struct AskModelPickerView: View {
    @Environment(TranscriptionViewModel.self) private var vm
    @Environment(MlxModelManager.self) private var mlx
    @Environment(\.openWindow) private var openWindow

    private var locked: Bool { vm.isSessionActive || vm.isBusy }

    /// A spinner while the DeepAgent's planner is loading. The vision model loads lazily on first
    /// use, so it's deliberately not part of this readiness spinner.
    private var loading: Bool {
        if case .loading = mlx.state(for: DeepAgentVariant.deepAgentID) { return true }
        return false
    }

    var body: some View {
        if vm.askEnabled {
            Button { openAskSettings() } label: { pill }
                .buttonStyle(.plain)
                .fixedSize()
                .opacity(locked ? 0.5 : 1)
                .disabled(locked)
                .help("DeepAgent answers your speech. Configure its models in the Ask settings tab.")
        }
    }

    private var pill: some View {
        HStack(spacing: 4) {
            if loading {
                ProgressView().controlSize(.mini).tint(Palette.accent)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
            }
            Text("DeepAgent")
                .font(.sans(11.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.accentGlow, lineWidth: 0.75)
        )
        .contentShape(Rectangle())
    }

    private func openAskSettings() {
        vm.pendingSettingsTab = .ask
        openWindow(id: MispherApp.settingsWindowID)
    }
}
