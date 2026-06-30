import DeepAgents
import SwiftUI

/// The Ask conversation card for the **Floating notch** and **Floating** presentations. It brings the
/// notch island's chat surface to the roomier floating overlays: the listening **Ask pill** while the
/// first prompt is captured, then the spoken text as a **user bubble** with the model's reply streamed
/// underneath - the same ``NotchChatView`` flow the Dynamic Island uses - but **without** the
/// past-conversations list or overflow menu. It stays open after the answer finishes until the user
/// presses Esc (``TranscriptionViewModel/stopPressed()``) or taps the close button.
///
/// Hosted by ``RecordingOverlayController`` and fed the same presentation-agnostic
/// ``NotchSessionStore`` the notch uses. The dynamic-notch views (``NotchView`` & co.) are reused only
/// by instantiation - nothing here edits them; the approval / error cards below are this card's own.
struct FloatingAskView: View {
    @EnvironmentObject private var store: NotchSessionStore
    @Environment(TranscriptionViewModel.self) private var vm
    @Environment(FloatingAskLayout.self) private var layout

    /// The card's content width; the hosting panel is this plus room on each side for the shadow.
    /// Matches the opened notch's effective content width (``NotchViewModel/openedSize`` 380 minus
    /// ``NotchView``'s 24pt inset) so the agent message wraps identically across floating, notch, and
    /// Dynamic Island -- they all host the same ``NotchChatView``. Keep these in sync.
    static let cardWidth: CGFloat = 356
    /// Transparent padding around the card so its soft drop shadow (``cardBackground`` casts radius 14,
    /// y 7) fully fades before the panel edge. Sized too tight and the borderless panel clips the
    /// shadow into a hard-edged box; it must clear the radius plus the downward offset.
    static let shadowInset: CGFloat = 24

    /// A throwaway session for ``NotchChatView`` - the floating card has no session list, and the chat
    /// view's `session` param is unused (its body reads only `store`).
    private static let placeholder = NotchSession(id: "floating-ask", title: "", subtitle: nil, preview: nil, date: nil)

    var body: some View {
        cardStack
            .frame(width: Self.cardWidth, alignment: .leading)
            .background(cardBackground)
            .padding(Self.shadowInset)
            .fixedSize(horizontal: false, vertical: true)
            // Report the natural height so the controller sizes the panel to it - the card grows stage
            // by stage (pill -> bubble -> reply) with no transparent, click-blocking dead zone.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { layout.contentHeight = $0 })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var cardStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.borderStrong).frame(height: 0.75)
            content
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Palette.bgDeep.opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Palette.borderStrong, lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.5), radius: 14, y: 7)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            BrandMarkView(size: 15)
            Text(vm.askSelectionLabel ?? "Ask")
                .font(.title(15, weight: .semibold))
                .foregroundStyle(Palette.fg)
                .lineLimit(1)
            Spacer(minLength: 6)
            readinessBadge
            newChatButton
            iconButton("macwindow", help: "Open in the main window") {
                vm.bringToFront()
                vm.chatMode = true
                vm.dismissAskOverlay()
            }
            iconButton("xmark", help: "Close") { vm.dismissAskOverlay() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// The header status: the selected Ask model's readiness (a colored dot + label). Generation has
    /// no separate state - once the model is loaded it simply reads "Ready". The listening state is
    /// carried by the pill in the body, so it isn't repeated here.
    @ViewBuilder private var readinessBadge: some View {
        switch store.modelReadiness {
        case .ready: readinessLabel(dot: Palette.success, "Ready")
        case .idle: readinessLabel(dot: Palette.warm, "Idle")
        case .failed: readinessLabel(dot: Palette.recRed, "Unavailable")
        case .noModel: readinessLabel(dot: Palette.fg3, "No model")
        case .loading: LoadingBadge()
        }
    }

    private func readinessLabel(dot: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).font(.sans(10)).foregroundStyle(Palette.fg3)
        }
    }

    /// Start a brand-new saved conversation (the previous one stays in `~/.mispher`); the chat view
    /// switches to the fresh thread as `store.threadId` updates synchronously.
    private var newChatButton: some View {
        iconButton("square.and.pencil", help: "New chat") { store.newSession() }
            .disabled(!store.hasAskModel)
            .opacity(store.hasAskModel ? 1 : 0.35)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.fg2)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Body

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .waitingForApproval:
            FloatingApprovalCard(store: store)
                .padding(.horizontal, 14)
        case .error(let message):
            FloatingErrorCard(message: message) { vm.dismissAskOverlay() }
                .padding(.horizontal, 14)
        default:
            NotchChatView(session: Self.placeholder, store: store)
        }
    }
}

/// The Ask model is loading into memory (download + warm-up): a blue dot that blinks (only the dot
/// animates) next to a static "Loading…", distinct from the other readiness states.
private struct LoadingBadge: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.blue)
                .frame(width: 6, height: 6)
                .opacity(pulsing ? 1 : 0.2)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            Text("Loading…")
                .font(.sans(10))
                .foregroundStyle(Palette.fg3)
        }
        .onAppear { pulsing = true }
    }
}

/// Animation/layout bridge from ``FloatingAskView`` (SwiftUI) to ``RecordingOverlayController``
/// (AppKit): the card measures its natural height and the controller sizes the panel to match, so the
/// card grows with the conversation instead of sitting in a fixed box. The card's width is fixed, so
/// height never feeds back into width - no oscillation.
@MainActor @Observable
final class FloatingAskLayout {
    var contentHeight: CGFloat = 0
}

// MARK: - Approval / error cards (this card's own, so the dynamic-notch `NotchView` stays untouched)

/// The human-in-the-loop tool approval prompt, with a 20-second auto-approve countdown. Mirrors the
/// notch's approval card but is driven straight off ``NotchSessionStore`` so the floating card can show
/// it without reaching into ``NotchView``.
private struct FloatingApprovalCard: View {
    @ObservedObject var store: NotchSessionStore
    @State private var countdown = 20
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 12) {
            if case .waitingForApproval(let toolName) = store.phase {
                titleRow
                detailBox(toolName: toolName)
                buttons
                Text("Auto-approve in \(countdown)s")
                    .font(.sans(10))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange)
            Text("Tool Approval Required")
                .font(.sans(13, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func detailBox(toolName: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(toolName)
                .font(.mono(12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
            if let args = arguments, !args.isEmpty {
                Text(args)
                    .font(.mono(11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            actionButton("Deny", color: .red.opacity(0.9), fill: .red.opacity(0.12)) { stop(); store.deny() }
            actionButton("Approve", color: .white, fill: .green.opacity(0.6)) { stop(); store.approve() }
        }
    }

    private func actionButton(_ title: String, color: Color, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.sans(12, weight: .medium))
                .foregroundColor(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var arguments: String? {
        guard let rows = store.pendingApproval?.argumentRows, !rows.isEmpty else { return nil }
        return rows.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private func start() {
        countdown = 20
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard case .waitingForApproval = store.phase else { stop(); return }
                countdown -= 1
                if countdown <= 0 { stop(); store.approve() }
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// An error notice for the floating Ask card, with a close button that dismisses the overlay.
private struct FloatingErrorCard: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                Text("Error")
                    .font(.sans(13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(message)
                .font(.sans(12))
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.vertical, 12)
    }
}
