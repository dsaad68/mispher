import SwiftUI

/// The chat window's collapsible left rail: the saved conversations (newest activity first) with a
/// "New conversation" action and a per-row delete. Reads the live list from ``MlxModelManager`` and resumes /
/// starts / deletes through it. Mirrors the notch session list (``NotchSessionListView``) visually, in
/// the chat window's glass language.
struct ConversationSidebarView: View {
    @Environment(MlxModelManager.self) private var mlx
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Hairline().opacity(0.6)
            if mlx.conversationList.isEmpty {
                Text(vm.askModelId == nil ? "Enable Ask to start chatting." : "No conversations yet.")
                    .font(.sans(11.5))
                    .foregroundStyle(Palette.fg2)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                list
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.white.opacity(0.03))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Conversations")
                .font(.title(20, weight: .semibold))
                .foregroundStyle(Palette.fg)
                .padding(.leading, 8)
            Spacer(minLength: 0)
            Button(action: newChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(vm.askModelId == nil ? Palette.fg3 : Palette.accent)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.askModelId == nil)
            .help("New conversation")
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(mlx.conversationList) { meta in
                    ConversationRow(
                        meta: meta,
                        isActive: meta.id == mlx.activeConversationId,
                        // Switch the conversation in the main window only - don't pop the notch/overlay.
                        open: { Task { await vm.resumeConversation(meta.id, activateOverlay: false) } },
                        delete: { mlx.deleteConversation(meta.id) }
                    )
                }
            }
        }
    }

    private func newChat() {
        guard let model = vm.askModelId else { return }
        mlx.startConversation(model: model)
    }
}

/// One conversation row: title (first user line) over a relative-time stamp, with a hover-revealed
/// delete. The active conversation gets an accent wash.
private struct ConversationRow: View {
    let meta: ConversationMeta
    let isActive: Bool
    let open: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.title.isEmpty ? "New conversation" : meta.title)
                        .font(.sans(12.5, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? Palette.accent : (hovering ? Palette.fg : Palette.fg1))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(Self.relativeTime(meta.updatedAt))
                        .font(.sans(10))
                        .foregroundStyle(Palette.fg3)
                }
                Spacer(minLength: 4)
                if hovering {
                    Button(action: delete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.fg2)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete conversation")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Palette.accentSoft : (hovering ? Color.white.opacity(0.04) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? Palette.accentGlow : .clear, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func relativeTime(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
