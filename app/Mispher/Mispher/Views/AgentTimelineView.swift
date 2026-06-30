import AppKit
import DeepAgents
import SwiftUI

// MARK: - Views

/// Renders an `[AgentStep]` timeline in order: dimmed collapsible reasoning, tool-call
/// disclosures, and to-do checklists — the way the model actually worked. The whole
/// timeline lives under one collapsible "Steps" disclosure so the reasoning and tool calls
/// can be folded away to keep the answer prominent. While `streaming`, the group is locked
/// open (live activity is visible); once the run finishes it collapses by default but stays
/// expandable.
struct AgentTimelineView: View {
    let steps: [AgentStep]
    /// Whether the run is still going (keeps the "Steps" group open while it streams).
    var streaming = false

    var body: some View {
        CollapsibleSection(
            icon: "list.bullet", iconColor: Palette.accent,
            label: "Steps · \(steps.count)", streaming: streaming
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { _, step in
                    switch step.kind {
                    case .reasoning(let text):
                        ReasoningView(text: text, streaming: false)
                    case .tool(let name, let input, let output, let imageURL, let subagent, let done):
                        ToolStepView(
                            name: name, input: input, output: output, imageURL: imageURL,
                            subagent: subagent, done: done
                        )
                    case .todos(let todos):
                        TodoStepView(todos: todos)
                    }
                }
            }
        }
    }
}

/// A single tool call as a collapsible disclosure (name header, input/output body),
/// auto-expanded until its result arrives. A captured image (e.g. a screenshot) renders as
/// a thumbnail that opens full-size in a sheet when clicked.
struct ToolStepView: View {
    let name: String
    let input: String
    let output: String?
    var imageURL: URL?
    /// For a `task` call, which subagent it was delegated to (shown in the header).
    var subagent: String?
    /// False while the tool is still running (keeps the disclosure open, output streaming).
    var done = true

    /// True while the captured image is shown enlarged in a sheet.
    @State private var enlarged = false

    /// "task → vision" for a subagent delegation; the friendly tool name otherwise.
    private var label: String {
        if name == "task", let subagent { return "task → \(subagent)" }
        return TranscriptionViewModel.friendlyToolName(name)
    }

    /// A distinct icon for a `task` (subagent delegation) so it reads apart from ordinary tools.
    private var icon: String {
        name == "task" ? "person.2" : "wrench.and.screwdriver"
    }

    var body: some View {
        CollapsibleSection(
            icon: icon,
            iconColor: Palette.accent,
            label: label,
            streaming: !done
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if !input.isEmpty { ToolIOLine(label: "input", value: input) }
                if let output, !output.isEmpty { ToolIOLine(label: "output", value: output) }
                if let imageURL, let image = NSImage(contentsOf: imageURL) {
                    thumbnail(image)
                }
            }
        }
        .sheet(isPresented: $enlarged) {
            if let imageURL, let image = NSImage(contentsOf: imageURL) {
                ImagePreview(image: image) { enlarged = false }
            }
        }
    }

    /// The captured image as a click-to-enlarge thumbnail. Tapping opens it full-size in a
    /// sheet; a magnifier badge and pointer cursor hint it's interactive.
    private func thumbnail(_ image: NSImage) -> some View {
        Button { enlarged = true } label: {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 160, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to enlarge")
        .pointerStyle(.link)
        .padding(.leading, 14)
        .padding(.top, 2)
    }
}

/// A captured image shown enlarged in a sheet so the user can read fine detail. The image
/// scales to fit a generous, resizable window; dismisses on Done or Esc.
private struct ImagePreview: View {
    let image: NSImage
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .buttonStyle(GlassPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding([.horizontal, .bottom], 12)
        }
        .frame(minWidth: 720, idealWidth: 1280, minHeight: 520, idealHeight: 900)
        .background(Palette.bgDeep)
    }
}

/// One labeled input/output line for a tool call.
struct ToolIOLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Text(label)
                .font(.sans(9.5, weight: .semibold))
                .foregroundStyle(Palette.fg3)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.sans(10.5))
                .foregroundStyle(Palette.fg2)
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 14)
    }
}

/// The to-do plan at one point in the timeline: a "Plan · done/total" header above the
/// checklist, always visible (the plan is the point of the step).
struct TodoStepView: View {
    let todos: [TodoItem]

    private var label: String {
        let done = todos.filter { $0.status == .completed }.count
        return "Plan · \(done)/\(todos.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.logoPurpleLight)
                Text(label)
                    .font(.sans(10, weight: .medium))
                    .foregroundStyle(Palette.fg2)
            }
            TodoChecklistView(todos: todos).padding(.leading, 4)
        }
    }
}

/// A compact to-do checklist: a circle for pending, a half-filled circle for in-progress,
/// and a ticked (struck-through) row for completed items.
struct TodoChecklistView: View {
    let todos: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(todos) { todo in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: symbol(todo.status))
                        .font(.system(size: 10))
                        .foregroundStyle(color(todo.status))
                    Text(todo.content)
                        .font(.sans(11))
                        .foregroundStyle(todo.status == .completed ? Palette.fg3 : Palette.fg2)
                        .strikethrough(todo.status == .completed, color: Palette.fg3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func symbol(_ status: TodoItem.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }

    /// Status colors mirroring the notch plan: dim pending, cyan in-progress, green done.
    private func color(_ status: TodoItem.Status) -> Color {
        switch status {
        case .pending: return Palette.fg3
        case .inProgress: return Palette.accent
        case .completed: return Palette.success
        }
    }
}
