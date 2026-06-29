import DeepAgentsMLX
import SwiftUI

/// Header dropdown for choosing the active transcription model, styled as the app's glass dropdown.
/// Only downloaded (or server-based) models are activatable; the rest are greyed with a "Download
/// in Settings" hint. Locked while a session is active.
struct ModelPickerView: View {
    @Environment(TranscriptionViewModel.self) private var vm

    private var locked: Bool { vm.isSessionActive || vm.isBusy }

    var body: some View {
        GlassDropdown(
            options: AsrModel.allCases.map { (value: $0, label: $0.displayName) },
            selection: Binding(get: { vm.selectedModel }, set: { vm.selectModel($0) }),
            isEnabled: !locked,
            displayLabel: vm.selectedModel.shortName,
            isOptionEnabled: { vm.canActivate($0) },
            disabledHint: "Download in Settings",
            icon: "waveform",
            isActive: vm.hasEngine
        )
    }
}
