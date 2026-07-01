import SwiftUI

/// A subtle glass pill that copies the current transcript, flashing "Copied"
/// briefly on success. Hidden when there's nothing to copy.
struct CopyButton: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        Button(action: vm.copyTranscript) {
            HStack(spacing: 5) {
                Image(systemName: vm.justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(vm.justCopied ? "Copied" : "Copy")
                    .font(.sans(11, weight: .medium))
            }
            .foregroundStyle(vm.justCopied ? Palette.success : Palette.fg1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(vm.hasCopyableText ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: vm.hasCopyableText)
        .animation(.easeInOut(duration: 0.15), value: vm.justCopied)
        .disabled(!vm.hasCopyableText)
    }
}
