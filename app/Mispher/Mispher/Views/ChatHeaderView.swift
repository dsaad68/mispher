import SwiftUI

/// The chat window's slim header: a sidebar toggle, the brand mark, the Ask model picker (the chat
/// target), a new-chat button, and the settings gear. Replaces ``HudHeaderView`` now that the window
/// is chat-only - there is no transcription mode to flip to. Conversation deletion lives per-row in
/// ``ConversationSidebarView``.
struct ChatHeaderView: View {
    @Binding var sidebarVisible: Bool

    @Environment(TranscriptionViewModel.self) private var vm
    @Environment(MlxModelManager.self) private var mlx
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 7) {
            Button { withAnimation(.easeInOut(duration: 0.22)) { sidebarVisible.toggle() } } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(sidebarVisible ? Palette.accent : Palette.fg2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sidebarVisible ? "Hide conversations" : "Show conversations")

            BrandMarkView(size: 18)
            Text("Mispher")
                .font(.title(16, weight: .semibold))
                .foregroundStyle(Palette.fg)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            // The Ask picker doubles as the chat model selector - one selector, shared with spoken Ask.
            AskModelPickerView()
            newChatButton

            Button { openWindow(id: MispherApp.settingsWindowID) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.fg2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// Start a brand-new conversation pinned to the current Ask model (the previous one stays saved).
    private var newChatButton: some View {
        Button {
            guard let model = vm.askModelId else { return }
            mlx.startConversation(model: model)
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(vm.askModelId == nil ? Palette.fg3 : Palette.fg2)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(vm.askModelId == nil)
        .help("New chat")
    }
}
