import DeepAgents
import DeepAgentsMLX
import SwiftUI

/// Compact HUD-header control for the post-recording translation: a glass menu of "Off" and the
/// target languages. Picking a language turns translation on; "Off" disables it. The translation
/// model is chosen in Settings ▸ Translate. The translation itself runs after recording stops.
/// Mutually exclusive with Ask. Accent-tinted when on, quiet otherwise; locked during a session.
struct TranslateLanguagePickerView: View {
    @Environment(TranscriptionViewModel.self) private var vm
    @Environment(MlxModelManager.self) private var mlx

    @State private var isOpen = false

    private var locked: Bool { vm.isSessionActive || vm.isBusy }
    private var isOn: Bool { vm.translationEnabled }

    /// A spinner while the chosen translation model is still loading/downloading.
    private var loading: Bool {
        guard isOn, let model = vm.translationModel else { return false }
        if case .loading = mlx.state(for: model) { return true }
        return false
    }

    var body: some View {
        Button { isOpen.toggle() } label: { triggerPill }
            .buttonStyle(.plain)
            .fixedSize()
            .opacity(locked ? 0.5 : 1)
            .disabled(locked)
            .animation(.easeOut(duration: 0.15), value: isOpen)
            .help(isOn
                ? "Translating to \(vm.translationTargetLanguage.displayName) "
                + "with \(vm.translationModel?.shortName ?? "the on-device model") when finished"
                : "Translate the transcript when finished")
            .glassDropdownPanel(isPresented: $isOpen) { menu }
    }

    private var triggerPill: some View {
        HStack(spacing: 4) {
            if loading {
                ProgressView().controlSize(.mini).tint(Palette.accent)
            } else {
                Image(systemName: "translate")
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(isOn ? vm.translationTargetLanguage.code : "Translate")
                .font(.sans(11, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isOn ? Palette.accent : Palette.fg2)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .foregroundStyle(isOn ? Palette.accent : Palette.fg2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isOn ? Palette.accentSoft : .white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isOn ? Palette.accentGlow : Palette.border, lineWidth: 0.75)
        )
        .contentShape(Rectangle())
    }

    private var menu: some View {
        GlassMenuCard {
            VStack(spacing: 1) {
                GlassDropdownRow(label: "Off", isSelected: !isOn) {
                    vm.translationEnabled = false
                    isOpen = false
                }
                GlassMenuSectionHeader(text: "Language")
                ForEach(vm.translationLanguages) { language in
                    GlassDropdownRow(
                        label: language.displayName,
                        isSelected: isOn && vm.translationTargetLanguage == language
                    ) {
                        vm.translationTargetLanguage = language
                        vm.translationEnabled = true
                        isOpen = false
                    }
                }
            }
        }
    }
}
