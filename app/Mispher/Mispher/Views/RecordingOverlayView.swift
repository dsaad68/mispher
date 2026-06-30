import SwiftUI

/// Content of the compact recording overlay -- a floating-notch pill, a small floating card, or a
/// Dynamic Island -- showing a live mic indicator and the streaming transcript while you dictate.
/// Reads the shared view model so the text updates as it's recognized; the hosting panel
/// (``RecordingOverlayController``) handles showing, positioning, and the island's animation.
struct RecordingOverlayRoot: View {
    @Environment(TranscriptionViewModel.self) private var vm

    /// The presentation that governs this panel's layout: Ask uses its own ``askPresentation``
    /// setting; voice modes use the shared ``recordingPresentation``.
    private var activePresentation: RecordingPresentation {
        vm.activeIntent == .ask ? vm.askPresentation : vm.recordingPresentation
    }

    var body: some View {
        Group {
            switch activePresentation {
            case .floating: FloatingOverlay()
            case .dynamicIsland: DynamicIslandOverlay()
            default: FloatingNotchOverlay()
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// A rounded pill showing the live transcript -- a mic pulse, the teleprompter text (growing up to
/// three lines), and a status dot. Shared by the floating notch and the floating card so they look
/// the same; only their placement differs (pinned under the notch vs. free-floating and draggable).
private struct RecordingPill: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let badge = intentBadge(for: vm.activeIntent) { badge }
            MicPulseView(mode: overlayPulse(vm.state))
            TeleprompterText(text: overlayText(vm), size: 12.5)
            overlayTrailing(vm)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.bgDeep.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Palette.borderStrong, lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.5), radius: 14, y: 7)
        )
    }
}

/// A small accent-tinted chip shown at the leading edge of every compact overlay (notch, floating,
/// and Dynamic Island) while a Rewrite or Translate session is active -- so the overlay reads as
/// the right mode rather than plain dictation. Returns nil for transcription and Ask.
@MainActor private func intentBadge(for intent: RecordIntent) -> IntentBadge? {
    switch intent {
    case .rewrite: return IntentBadge(icon: "wand.and.stars", label: "Rewrite")
    case .translate: return IntentBadge(icon: "translate", label: "Translate")
    case .transcription, .ask, .askContinue: return nil
    }
}

private struct IntentBadge: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 3.5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.sans(10, weight: .semibold))
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Palette.accentSoft)
                .overlay(Capsule(style: .continuous).strokeBorder(Palette.accent.opacity(0.30), lineWidth: 0.75))
        )
        .fixedSize() // keep the chip intact; the transcript yields the width instead
    }
}

/// The "Floating notch" presentation: the pill pinned just under the notch. In Ask mode it hosts the
/// multi-turn conversation card (``FloatingAskView``) instead, growing downward from the notch.
private struct FloatingNotchOverlay: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        if vm.activeIntent == .ask {
            FloatingAskView()
        } else {
            VStack(spacing: 0) {
                RecordingPill()
                    // Room for the pill's soft drop shadow (radius 14, y 7) so the borderless panel
                    // doesn't clip it into a hard-edged box at its sides.
                    .padding(.horizontal, 16)
                    .padding(.top, 7)
                    .padding(.bottom, 3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The "Floating" presentation: the same pill, but free-floating and draggable anywhere on the
/// desktop. Extra padding gives the drop shadow room since it isn't tucked under the notch. In Ask
/// mode it hosts the multi-turn conversation card instead, filling the (taller) panel.
private struct FloatingOverlay: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        if vm.activeIntent == .ask {
            FloatingAskView()
        } else {
            VStack(spacing: 0) {
                RecordingPill()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// A Dynamic Island that grows out of the notch while dictating: the black hugs the notch (square
/// top corners that merge into it) and the content -- styled like the floating notch, just larger --
/// drops below the notch with the live transcript, growing up to three lines as you speak. It pops
/// out of the notch when recording starts and retracts when it ends (driven by ``IslandPresenter``,
/// set by ``RecordingOverlayController``). Like the floating notch it has no controls; the
/// transcript and the pulse colour carry the state.
private struct DynamicIslandOverlay: View {
    @Environment(TranscriptionViewModel.self) private var vm
    @Environment(IslandPresenter.self) private var island

    private var expanded: Bool { island.expanded }
    /// The notch / menu-bar height, so the content clears the hardware notch while the black
    /// background reaches up behind it.
    private var topInset: CGFloat { island.notchInset }

    var body: some View {
        VStack(spacing: 0) {
            islandBody
                .scaleEffect(expanded ? 1 : 0.75, anchor: .top)
                .opacity(expanded ? 1 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: expanded)
            // The dictation pill hugs the top; the Spacer fills the rest of the island.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var islandBody: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset) // the strip that sits behind the notch
            content
        }
        .frame(width: 360)
        .background(shape.fill(.black))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }

    /// Square top corners so the black merges with the notch and the screen edge; rounded bottom for
    /// the signature dynamic-island curve.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 22,
            bottomTrailingRadius: 22,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    /// Mic indicator + live transcript + status dot, mirroring the floating notch but with larger
    /// text, growing up to three lines. (Ask on the Dynamic Island is hosted separately by
    /// ``AskNotchController``, so this island only ever shows dictation / rewrite / translate.)
    private var content: some View {
        HStack(alignment: .center, spacing: 11) {
            if let badge = intentBadge(for: vm.activeIntent) { badge }
            MicPulseView(mode: overlayPulse(vm.state))
            TeleprompterText(text: overlayText(vm), size: 14)
            overlayTrailing(vm)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The live transcript for the compact overlays. It grows up to `maxLines`; once it overflows it
/// scrolls like a teleprompter -- the newest line stays at the bottom and older lines slide up out
/// of view. The window is sized to exactly `min(textHeight, maxLines)` (so short text isn't padded
/// with empty space), and the full text is offset upward to reveal its tail, animated only when the
/// line count changes so streaming words don't cause jitter.
private struct TeleprompterText: View {
    let text: String
    let size: CGFloat
    var weight: Font.Weight = .medium
    var maxLines = 3

    @State private var textHeight: CGFloat = 0
    @State private var cap: CGFloat = 0

    /// Only the tail can ever be visible, so cap what we render to keep the text view bounded.
    private var shown: String { String(text.suffix(500)) }
    private var probe: String { Array(repeating: "Ag", count: maxLines).joined(separator: "\n") }
    private var windowHeight: CGFloat? {
        guard cap > 0, textHeight > 0 else { return nil }
        return min(textHeight, cap)
    }

    private var overflow: CGFloat { cap > 0 ? max(0, textHeight - cap) : 0 }

    var body: some View {
        Text(shown)
            .font(.sans(size, weight: weight))
            .foregroundStyle(Palette.fg)
            .fixedSize(horizontal: false, vertical: true) // lay out every line at full height
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { textHeight = $0 })
            .offset(y: -overflow) // slide up so the newest lines show
            .frame(height: windowHeight, alignment: .top)
            .clipped()
            .background(alignment: .topLeading) {
                // Measure the exact height of `maxLines` lines for this font (precise, with leading).
                Text(probe)
                    .font(.sans(size, weight: weight))
                    .lineLimit(maxLines)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { cap = $0 })
            }
            .animation(.easeInOut(duration: 0.3), value: textHeight)
    }
}

// MARK: - Shared helpers

func overlayPulse(_ state: RecordingState) -> MicPulseView.Mode {
    switch state {
    case .recording, .preparing, .finalizing: return .recording
    case .paused: return .paused
    default: return .idle
    }
}

/// The text shown in the overlay: a status hint before any words land, then the live transcript.
@MainActor func overlayText(_ vm: TranscriptionViewModel) -> String {
    // Rewrite/translate run with state idle once recording stops; show their own hint rather than
    // leaving the spoken text (which reads as if it were still listening).
    if vm.isRewriting { return "Rewriting…" }
    if vm.isTranslating { return "Translating…" }
    let text = vm.partialText.isEmpty ? vm.finalText : vm.partialText
    if !text.isEmpty { return text }
    switch vm.state {
    case .preparing: return "Starting…"
    case .finalizing: return vm.isCleaningUp ? "Cleaning up…" : "Finishing…"
    case .paused: return "Paused."
    default: return "Listening…"
    }
}

@MainActor @ViewBuilder private func overlayTrailing(_ vm: TranscriptionViewModel) -> some View {
    if vm.isBusy || vm.isCleaningUp || vm.isRewriting || vm.isTranslating {
        ProgressView().controlSize(.small).tint(Palette.fg2)
    } else {
        // Amber while paused (matching the pulse), red while actively recording.
        Circle().fill(vm.isPaused ? Palette.warm : Palette.recRed).frame(width: 7, height: 7)
    }
}
