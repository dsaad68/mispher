import DeepAgentsMLX
import SwiftUI

/// Settings section listing every model with its download state: download /
/// progress / delete, an "Active" badge for the current model, the int8↔fp32
/// toggle for CTC, and a server hint for Qwen.
struct ModelManagerView: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Transcription models")
            Text("Speech-to-text engines that run on-device. "
                + "Download the ones you want; pick one from the model menu "
                + "in the toolbar to transcribe.")
                .font(.sans(11))
                .foregroundStyle(Palette.fg2)
                .fixedSize(horizontal: false, vertical: true)

            SettingsCard {
                ForEach(Array(AsrModel.allCases.enumerated()), id: \.element) { index, model in
                    ModelRow(model: model)
                    if index < AsrModel.allCases.count - 1 {
                        Hairline().opacity(0.5)
                    }
                }
            }
        }
    }
}

private struct ModelRow: View {
    @Environment(TranscriptionViewModel.self) private var vm
    let model: AsrModel

    private var state: ModelDownloadState { vm.downloadStates[model] ?? .unknown }
    private var isSelected: Bool { vm.selectedModel == model }
    private var isActive: Bool { isSelected && vm.hasEngine }

    var body: some View {
        ModelRowLayout(
            title: model.displayName,
            subtitle: model.subtitle,
            badges: { if isActive { Badge(text: "Active") } },
            trailing: { trailing }
        )
    }

    private var trailing: some View {
        HStack(spacing: 12) {
            useButton
            stateControl
        }
    }

    /// "Use" makes this the active transcription model right from Settings (the same effect as
    /// picking it in the toolbar model menu). Shown for any model that can be activated now -
    /// downloaded, or server-backed like Qwen - and isn't already the selected one. Locked during a
    /// capture session or while a model is being prepared.
    @ViewBuilder private var useButton: some View {
        if vm.canActivate(model), !isSelected {
            Button { vm.selectModel(model) } label: {
                Text("Use")
                    .font(.sans(11, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .disabled(vm.isSessionActive || vm.isBusy)
            .help("Make this the active transcription model")
        }
    }

    @ViewBuilder private var stateControl: some View {
        if model.requiresLocalServer {
            // Server-backed (Qwen): nothing to download/delete — the "llama-server" note is
            // already in the subtitle. Activation is handled by "Use" above.
            EmptyView()
        } else {
            switch state {
            case .downloading(let progress):
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .frame(width: 68)
                        .tint(Palette.accent)
                    Text("\(Int(progress * 100))%")
                        .font(.mono(10))
                        .foregroundStyle(Palette.fg2)
                        .monospacedDigit()
                }
            case .downloaded:
                Button { vm.deleteModel(model) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.fg2)
                }
                .buttonStyle(.plain)
                .disabled(vm.isSessionActive)
                .help("Delete downloaded files")
            case .failed(let reason):
                Button { vm.downloadModel(model) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.arrow.circlepath")
                        Text("Retry")
                            .font(.sans(11, weight: .medium))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.recRed)
                }
                .buttonStyle(.plain)
                .help(reason)
            case .notDownloaded, .unknown:
                Button { vm.downloadModel(model) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text("Download")
                            .font(.sans(11, weight: .medium))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
