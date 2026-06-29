import Foundation
import MarkdownUI
import SwiftUI

/// Renders one chat history item by type. Ported 1:1 from copilot-island's `MessageItemView`, plus a
/// `.todos` case for Mispher's agent to-do plan.
struct MessageItemView: View {
    let item: ChatHistoryItem

    var body: some View {
        switch item.type {
        case .user(let content): UserMessageView(content: content)
        case .assistant(let content, let streaming): AssistantMessageView(content: content, streaming: streaming)
        case .toolCall(let tool): ToolCallView(tool: tool)
        case .thinking(let content, let streaming): ThinkingView(content: content, streaming: streaming)
        case .todos(let todos): TodoListView(todos: todos)
        }
    }
}

/// A user message (right-aligned blue bubble). Ported 1:1 from copilot-island.
struct UserMessageView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 40)
            Text(content)
                .font(.sans(12))
                .foregroundColor(.white.opacity(0.95))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.3))
                .cornerRadius(10)
                .textSelection(.enabled)
        }
    }
}

/// An assistant message (left-aligned, purple dot + markdown). Ported from copilot-island. The answer
/// renders as formatted Markdown the whole time, including while it streams, so it never visibly
/// "pops" from plain text to Markdown when the turn finishes (matching the HUD's `MarkdownText`).
/// MarkdownUI re-parses its entire content on every change, but ``NotchSessionStore/scheduleRefresh()``
/// already coalesces token bursts to ~16 Hz, so it re-parses only a few times a second rather than per
/// token. (The `streaming` flag is kept for parity with the other items / a future live affordance; if
/// very long answers ever jank, switch to stable-prefix block rendering so only the trailing block
/// re-parses each tick.)
struct AssistantMessageView: View {
    let content: String
    var streaming = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.purple.opacity(0.6))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            Markdown(content)
                .markdownTextStyle {
                    // Agent messages read in the serif (Sentient ExtraLight), matching the HUD.
                    FontFamily(.custom(Typeface.serifFamily))
                    FontSize(13)
                    // Full-white for contrast: the ExtraLight serif needs it to stay legible.
                    ForegroundColor(.white)
                    // Sentient ExtraLight sets tight by default; a little tracking unclumps the glyphs.
                    TextTracking(0.5)
                }
                .markdownBlockStyle(\.codeBlock) { configuration in
                    configuration.label
                        .padding(8)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Near-flush trailing gutter so the serif lines run as wide as possible -- the notch is cramped.
            Spacer(minLength: 4)
        }
    }
}

/// A tool call as a collapsible disclosure, styled like the HUD's `ToolStepView`: a wrench icon, the
/// friendly tool name, and a status word, collapsed by default. Expanding shows the input and the
/// output (pretty-printed when the output is JSON).
struct ToolCallView: View {
    let tool: ToolCallItem
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                    Text(displayName)
                        .font(.sans(11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                    Spacer()
                    statusBadge
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !tool.input.isEmpty { ioLine("input", tool.input, mono: false) }
                    if let result = tool.result, !result.isEmpty {
                        ioLine("output", Self.structuredOutput(result), mono: true)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }

    private var displayName: String { TranscriptionViewModel.friendlyToolName(tool.name) }

    @ViewBuilder private var statusBadge: some View {
        switch tool.status {
        case .running:
            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
        case .success:
            Text("Success").font(.sans(10)).foregroundColor(.green.opacity(0.75))
        case .error(let message):
            Text(message?.localizedCaseInsensitiveContains("rejected") == true ? "Rejected" : "Error")
                .font(.sans(10))
                .foregroundColor(.red.opacity(0.85))
        }
    }

    private func ioLine(_ label: String, _ value: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.sans(9, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
            Text(value)
                .font(mono ? .mono(10) : .sans(10))
                .foregroundColor(.white.opacity(0.55))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Pretty-print the output as JSON when it parses as JSON (so it reads as structure, not a single
    /// escaped string); otherwise return it as-is. Capped so a huge result doesn't dominate the notch.
    static func structuredOutput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pretty: String
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(
               withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
           ),
           let string = String(data: prettyData, encoding: .utf8) {
            pretty = string
        } else {
            pretty = raw
        }
        return pretty.count > 1500 ? String(pretty.prefix(1500)) + "\n…" : pretty
    }
}

/// Collapsible reasoning block (brain icon, orange accent), ported from copilot-island. Labelled
/// "Thinking", with animated dots while the reasoning is still streaming. Stays collapsed by default.
struct ThinkingView: View {
    let content: String
    var streaming: Bool = false
    @State private var isExpanded = false

    /// Auto-expanded (and locked open) while the reasoning streams, so it's visible live; collapsible
    /// once it's done.
    private var showContent: Bool { isExpanded || streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)

                    Text("Thinking")
                        .font(.sans(11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))

                    if streaming { ThinkingDots() }

                    Image(systemName: showContent ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.4))

                    Spacer()
                }
                // Make the whole header row tappable (matching ToolCallView). Without this the hit
                // area is just the glyphs, and NotchPanel's per-point hit-test (Dynamic Island) reposts
                // near-misses on the tiny chevron instead of toggling.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(streaming)

            if showContent {
                Markdown(content)
                    .markdownTextStyle {
                        // Agent thinking renders in italic sans (Satoshi).
                        FontFamily(.custom(Typeface.sansFamily))
                        FontSize(11)
                        ForegroundColor(.white.opacity(0.6))
                    }
                    .italic()
                    .padding(.leading, 26)
                    // Secondary reasoning stays in a narrower column -- only the answer runs full-width.
                    .padding(.trailing, 24)
            }
        }
    }
}

/// Three small dots that fade in sequence - the "Thinking…" indicator shown while reasoning streams.
private struct ThinkingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 3, height: 3)
                    .opacity(animating ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

/// The agent's to-do plan (Mispher addition; copilot-island has no equivalent), styled to match the
/// tool-call rows.
struct TodoListView: View {
    let todos: [NotchTodo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 10))
                    .foregroundColor(.logoPurpleLight)
                Text("Plan")
                    .font(.sans(11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
            }

            ForEach(todos) { todo in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: symbol(for: todo.status))
                        .font(.system(size: 9))
                        .foregroundColor(color(for: todo.status))
                    Text(todo.content)
                        .font(.sans(10))
                        .foregroundColor(.white.opacity(todo.status == .completed ? 0.4 : 0.6))
                        .strikethrough(todo.status == .completed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }

    private func symbol(for status: NotchTodo.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func color(for status: NotchTodo.Status) -> Color {
        switch status {
        case .pending: return .white.opacity(0.3)
        case .inProgress: return .logoCyan
        case .completed: return .green
        }
    }
}
