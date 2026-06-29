import DeepAgentsMLX
import SwiftUI

/// A state-colored dot plus a concise status label — used in the footer.
struct StatusBarView: View {
    @Environment(TranscriptionViewModel.self) private var vm

    private var color: Color {
        switch vm.state {
        case .idle: return vm.hasEngine ? Palette.success : Palette.fg3
        case .preparing, .finalizing, .paused: return Palette.warm
        case .recording: return Palette.accent
        case .error: return Palette.recRed
        }
    }

    private var label: String {
        switch vm.state {
        case .idle:
            return vm.hasEngine ? "\(vm.selectedModel.shortName) ready" : "No model loaded"
        case .preparing: return "Preparing…"
        case .finalizing: return "Finalizing…"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .error: return vm.statusMessage
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.6), radius: 4)
            Text(label)
                .font(.sans(11.5))
                .foregroundStyle(Palette.fg2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
