import SwiftUI

/// The notch conversation, fed by ``NotchSessionStore/history`` (derived live from `MlxModelManager`).
/// Mispher additions over copilot-island's `ChatView`:
///  - while recording the first prompt of a thread it shows the dictation-style **Ask pill** (mic +
///    live transcript), not a bubble - the spoken text only becomes a user bubble once the turn is
///    sent;
///  - the message area sizes to its content, so the notch grows stage by stage (pill -> user bubble
///    -> + collapsed reasoning -> + streaming answer) and only scrolls once it hits the cap;
///  - a compose row lets you type instead of speaking.
struct NotchChatView: View {
    let session: NotchSession
    @ObservedObject var store: NotchSessionStore

    @State private var footerHovered = false
    @State private var draft = ""
    @State private var measuredHeight: CGFloat = 80
    @FocusState private var composerFocused: Bool

    /// The amount of message area shown before it starts scrolling (the notch caps here).
    private let maxScrollHeight: CGFloat = 300

    /// The first turn of an empty thread *while capturing*: show the compact Ask pill instead of the
    /// full chat, so the notch stays the size of the dictation overlay until the prompt lands.
    /// `store.isCapturing` spans recording + finalizing (so the pill holds across the commit gap
    /// without flashing the empty chat), but is false once idle - so clearing the thread or starting a
    /// new session drops back to the full chat with its compose row rather than a stuck "Listening…".
    private var isCompactListening: Bool { store.history.isEmpty && store.isCapturing }

    var body: some View {
        Group {
            if isCompactListening {
                askPill.transition(.opacity)
            } else {
                fullChat.transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.88), value: isCompactListening)
    }

    // MARK: - Listening pill (first prompt)

    /// Mirrors the dictation overlay: a mic pulse and the live transcript, growing with your words.
    private var askPill: some View {
        HStack(spacing: 11) {
            MicPulseView(mode: store.capturePulse)
            Text(store.liveTranscript.isEmpty ? "Listening…" : store.liveTranscript)
                .font(.sans(14))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Full chat

    private var fullChat: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No header row here - the brand, back, and new-chat all live in the notch's ear above,
            // so the conversation starts right at the top.
            messages
                .padding(.top, 4)

            footer
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.18)) { footerHovered = hovering }
                }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if store.history.isEmpty {
                        Text("Ask anything by voice, or type below.")
                            .font(.sans(12))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(store.history) { item in
                        MessageItemView(item: item).id(item.id)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { measuredHeight = $0 })
            }
            // Hide the scroller. It's an auto-hiding overlay bar that flashes in the instant content
            // exceeds the frame; while the frame grows token by token the content keeps momentarily
            // overflowing, so the bar flickers nonstop until the height cap is hit. This is a compact
            // chat card with no need for a visible bar, so suppress it outright.
            .scrollIndicators(.hidden)
            // Size to content so the notch grows stage by stage; scroll only past the cap. Snap the
            // frame to the measured height - do NOT animate it. An animated frame lags a step behind
            // the content as tokens stream, so the content overflows its own still-growing frame every
            // tick - which is what flashed the scroller and jolted the autoscroll target. Snapping
            // keeps frame == content below the cap, so there's never a transient overflow (and the card
            // still grows smoothly: the panel resize is driven off this same measured height).
            .frame(height: min(measuredHeight, maxScrollHeight))
            // Pin to the bottom as content grows. Against the snapped frame this is a no-op below the
            // cap (everything already fits) and a clean glue-to-newest past it; animate only the
            // discrete arrival of a whole new message, not the per-token growth.
            .onChange(of: measuredHeight) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.history.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: - Footer (compose, or the live prompt of a follow-up)

    @ViewBuilder private var footer: some View {
        if store.isCapturing {
            HStack(spacing: 8) {
                MicPulseView(mode: store.capturePulse)
                Text(store.liveTranscript.isEmpty ? "Listening…" : store.liveTranscript)
                    .font(.sans(12))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        } else if footerHovered || composerFocused || !draft.isEmpty {
            composeRow.transition(.opacity)
        } else {
            // Resting state - including while the agent is answering - keeps the notch slim with just
            // a faint hint, expanded into the full input (and its stop button) on hover or focus.
            composeHint.transition(.opacity)
        }
    }

    private var composeHint: some View {
        HStack(spacing: 6) {
            Image(systemName: store.isGenerating ? "stop.circle" : "text.bubble")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
            Text(store.isGenerating ? "Press esc to stop" : "Type a message")
                .font(.sans(11))
                .foregroundColor(.white.opacity(0.3))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var composeRow: some View {
        HStack(spacing: 6) {
            TextField("Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.sans(12))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1 ... 4)
                .focused($composerFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .onSubmit(send)
                .disabled(store.isGenerating)

            if store.isGenerating {
                Button(action: store.cancel) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(canSend ? .logoCyan : .white.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isGenerating
    }

    private func send() {
        guard canSend else { return }
        store.send(draft)
        draft = ""
    }
}
