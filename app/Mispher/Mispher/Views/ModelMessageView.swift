import DeepAgents
import SwiftUI

/// Renders a model's reply: a collapsible, dimmed `<think>…</think>` reasoning
/// section (reasoning models like LFM2.5 8B-A1B emit one) followed by the final
/// answer as full markdown. Shared by the Settings chat sidebar and the main
/// view's spoken-prompt answer.
struct ModelMessageView: View {
    let text: String
    var fontSize: CGFloat = 15

    var body: some View {
        let parsed = ThinkingSplit.split(text)
        VStack(alignment: .leading, spacing: 6) {
            if let thinking = parsed.thinking {
                ReasoningView(text: thinking, streaming: parsed.answer.isEmpty)
            }
            if !parsed.answer.isEmpty {
                MarkdownText(parsed.answer, fontSize: fontSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A calm three-dot "typing" animation shown while the model composes its first
/// tokens — quieter than a spinner paired with a big "Thinking…" label.
struct ThinkingIndicator: View {
    var tint: Color = Palette.accent
    var dot: CGFloat = 6
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle()
                    .fill(tint)
                    .frame(width: dot, height: dot)
                    .opacity(animating ? 1 : 0.25)
                    .scaleEffect(animating ? 1 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

// `ThinkingSplit` lives in `Agents/Core/ThinkingSplit.swift` (shared with the JSONL log).

/// Collapsible reasoning disclosure. Auto-expanded (and locked open) while the
/// reply is still streaming its `<think>` block, collapsible once the answer
/// begins.
struct ReasoningView: View {
    let text: String
    var streaming: Bool
    @State private var expanded = false

    private var showText: Bool { expanded || streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: showText ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.fg3)
                    Image(systemName: "brain")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.warm)
                    Text(streaming ? "Thinking…" : "Reasoning")
                        .font(.sans(10, weight: .medium))
                        .foregroundStyle(Palette.fg2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(streaming)

            if showText {
                // Agent thinking renders in italic sans (Satoshi); only finished answers use the serif.
                MarkdownText(text, color: Palette.fg3, fontSize: 11, bodyFont: .sansItalic)
                    .padding(.leading, 4)
            }
        }
    }
}

/// A collapsible disclosure styled like ``ReasoningView``: a dimmed header row
/// (chevron + icon + label) that toggles an arbitrary content body. While `streaming`
/// is true it's forced open and locked (matching the reasoning section's behavior).
/// Used for the agent's tool-call log and to-do plan beneath an answer.
struct CollapsibleSection<Content: View>: View {
    let icon: String
    /// Tint for the section's leading icon (the chevron + label stay dim). Defaults to the dim
    /// foreground so existing call sites are unchanged; the agent timeline passes an accent per type.
    var iconColor: Color = Palette.fg3
    let label: String
    var streaming: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var expanded = false
    private var showContent: Bool { expanded || streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: showContent ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.fg3)
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundStyle(iconColor)
                    Text(label)
                        .font(.sans(10, weight: .medium))
                        .foregroundStyle(Palette.fg2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(streaming)

            if showContent {
                content()
                    .padding(.leading, 4)
            }
        }
    }
}
