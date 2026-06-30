import DeepAgents
import DeepAgentsMLX
import SwiftUI

/// Settings ▸ Local models: manage which on-device LFM2.5 models are downloaded to disk.
/// Mirrors ASR Models — each row is Download / Delete (no use/select toggle). The active
/// model is chosen in the HUD (the Ask / chat picker), which loads it on demand.
struct LocalModelsView: View {
    @Environment(MlxModelManager.self) private var mlx

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "On-device models")
            Text("LiquidAI LFM2.5 language & vision models that run on-device. "
                + "Download the ones you want; pick one from the Ask / chat menu "
                + "in the toolbar to use it (it loads on demand).")
                .font(.sans(11))
                .foregroundStyle(Palette.fg2)
                .fixedSize(horizontal: false, vertical: true)

            SettingsCard {
                ForEach(Array(MlxModel.catalog.enumerated()), id: \.element.id) { index, model in
                    MlxModelRow(model: model)
                    if index < MlxModel.catalog.count - 1 {
                        Hairline().opacity(0.5)
                    }
                }
            }
        }
        .onAppear { mlx.refreshDiskStates() }
    }
}

// MARK: - Model row (download / delete)

private struct MlxModelRow: View {
    @Environment(MlxModelManager.self) private var mlx
    let model: MlxModel

    private var disk: MlxModelManager.DiskState { mlx.diskState(for: model) }
    private var isLoaded: Bool {
        if case .ready = mlx.state(for: model) { return true } else { return false }
    }

    var body: some View {
        ModelRowLayout(
            title: model.displayName,
            subtitle: "\(model.detail) · ~\(model.sizeLabel)",
            badges: {
                if model.isVision { Badge(text: "Vision") }
                if isLoaded { Badge(text: "Loaded", tint: Palette.success) }
            },
            trailing: { trailing }
        )
    }

    @ViewBuilder private var trailing: some View {
        switch disk {
        case .downloading(let fraction):
            HStack(spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 68).tint(Palette.accent)
                    Text("\(Int(fraction * 100))%")
                        .font(.mono(10)).foregroundStyle(Palette.fg2).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small).tint(Palette.accent)
                }
            }
        case .downloaded:
            Button { mlx.deleteFromDisk(model) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.fg2)
            }
            .buttonStyle(.plain)
            .help("Delete downloaded files")
        case .failed(let reason):
            Button { mlx.downloadToDisk(model) } label: {
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
            Button { mlx.downloadToDisk(model) } label: {
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
