import SwiftUI

/// The notch's "home" screen: a status badge plus the list of conversations. Adapted from
/// copilot-island's `SessionListView` - the Copilot-CLI setup checklist, plugin recommendation, and
/// `cwd`/`model`/`tool` rows are dropped (Mispher runs the agent on-device), leaving the status badge
/// and the conversation list. Mispher normally has a single live Ask thread, so the list usually
/// holds one row that opens straight into the chat.
struct NotchSessionListView: View {
    @ObservedObject var store: NotchSessionStore
    var onSelectSession: (NotchSession) -> Void

    /// Measured height of the list, so the notch hugs a short list instead of a `ScrollView`
    /// stretching to fill the panel's max height.
    @State private var listHeight: CGFloat = 0
    private let maxListHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conversations")
                    .font(.sans(12.5, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                statusBadge
            }

            Rectangle()
                .fill(LinearGradient(
                    colors: [.clear, .white.opacity(0.12), .clear],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(height: 1)

            if store.recentSessions.isEmpty {
                Text(store.isCapturing ? "Listening…" : "Ask anything by voice.")
                    .font(.sans(12))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                recentSessionsList
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var statusBadge: some View {
        let (color, text) = statusInfo
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.sans(10))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.15))
        .cornerRadius(7)
    }

    private var statusInfo: (Color, String) {
        switch store.phase {
        case .idle: return (.green, "Ready")
        case .processing: return (.blue, "Processing")
        case .runningTool(let name): return (.purple, name)
        case .waitingForApproval(let toolName): return (.orange, "Approve \(toolName)?")
        case .error(let message): return (.red, message)
        case .ended: return (.green, "Ready")
        }
    }

    private var recentSessionsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.recentSessions) { session in
                    sessionRow(session)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { listHeight = $0 })
        }
        // Hug the content (so one conversation isn't a full-height panel); scroll only past the cap.
        .frame(height: min(listHeight, maxListHeight))
    }

    /// One conversation: the opening line (truncated with an ellipsis) on the left, a relative
    /// "x min ago" stamp on the right - a chat-list style row.
    private func sessionRow(_ session: NotchSession) -> some View {
        HStack(spacing: 8) {
            Text(session.preview ?? session.title)
                .font(.sans(12))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)

            if store.sessionsWithNewMessages.contains(session.id) {
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 6, height: 6)
            }

            Spacer(minLength: 8)

            if let date = session.date {
                Text(Self.relativeTime(date))
                    .font(.sans(10))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            store.sessionsWithNewMessages.remove(session.id)
            onSelectSession(session)
        }
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
