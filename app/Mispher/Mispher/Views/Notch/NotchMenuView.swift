import SwiftUI

/// The notch's overflow menu, opened from the home header. Adapted from copilot-island's
/// `NotchMenuView`, slimmed to Mispher's two overflow actions - opening the conversation in the main
/// window and the app's Settings. (New chat now lives in the header ear beside the menu button.) The
/// `MenuRow` styling is kept verbatim.
struct NotchMenuView: View {
    @ObservedObject var store: NotchSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(icon: "macwindow", label: "Open in main window") {
                store.openInMainWindow()
            }

            if !store.history.isEmpty {
                MenuRow(
                    icon: "rectangle.compress.vertical",
                    label: store.isCompacting ? "Compacting context…" : "Compact conversation"
                ) {
                    store.compactConversation()
                }
            }

            MenuRow(icon: "gearshape", label: "Settings…") {
                store.openSettings()
            }
        }
        .padding(.vertical, 4)
    }
}

/// A single tappable menu row with hover highlight. Ported 1:1 from copilot-island.
struct MenuRow: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(isDestructive ? .red : .white.opacity(0.6))
                    .frame(width: 20)

                Text(label)
                    .font(.sans(13))
                    .foregroundColor(isDestructive ? .red : .white.opacity(0.8))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovered ? Color.white.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
