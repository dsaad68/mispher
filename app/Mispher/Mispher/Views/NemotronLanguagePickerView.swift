import SwiftUI

/// Compact HUD-header control for the Nemotron Multilingual ASR model's spoken-language
/// hint. Shown only while Nemotron is the active transcription model (see ``HudHeaderView``),
/// it mirrors the Translate language picker's glass-pill style. Picking a language re-prepares
/// the engine if Nemotron is running; locked during a session.
struct NemotronLanguagePickerView: View {
    @Environment(TranscriptionViewModel.self) private var vm

    private var locked: Bool { vm.isSessionActive || vm.isBusy }

    /// Compact label for the pill (the full name is in the menu). "auto" → "Auto", otherwise
    /// the leading language code, e.g. "en-US" → "EN", "zh-CN" → "ZH".
    private var shortCode: String {
        let code = vm.nemotronLanguage
        return code == "auto" ? "Auto" : String(code.prefix(2)).uppercased()
    }

    var body: some View {
        Menu {
            ForEach(NemotronMultilingualEngine.supportedLanguages) { language in
                Button { vm.setNemotronLanguage(language.code) } label: {
                    if vm.nemotronLanguage == language.code {
                        Label(language.name, systemImage: "checkmark")
                    } else {
                        Text(language.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                Text(shortCode)
                    .font(.sans(11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.fg2)
            }
            .foregroundStyle(Palette.fg2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(locked ? 0.5 : 1)
        .disabled(locked)
        .help("Spoken language for Nemotron transcription")
    }
}
