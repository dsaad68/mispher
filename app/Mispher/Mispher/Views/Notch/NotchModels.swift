import DeepAgents
import SwiftUI

// Ported 1:1 from the copilot-island prototype (https://github.com/dsaad68/copilot-island), then
// re-wired to Mispher's on-device DeepAgent: the views and styling are kept verbatim; only the data
// source (a Copilot-CLI socket + events.jsonl) is swapped for `MlxModelManager` (see
// ``NotchSessionStore``). This file holds the shared models / colours / shape the notch UI uses.

// MARK: - Logo palette (copilot-island Color+Logo, verbatim)

extension Color {
    /// Primary purple (#6E40C9) - GitHub Copilot / logo base.
    static let logoPurple = Color(red: 0.43, green: 0.25, blue: 0.79)
    /// Soft purple (#A78BFA) - gradients, glows.
    static let logoPurpleLight = Color(red: 0.65, green: 0.55, blue: 0.98)
    /// Cyan accent (#22D3EE) - tech / starburst highlight.
    static let logoCyan = Color(red: 0.13, green: 0.83, blue: 0.93)

    /// Linear gradient purple -> cyan.
    static var logoGradient: LinearGradient {
        LinearGradient(colors: [.logoPurple, .logoPurpleLight, .logoCyan], startPoint: .leading, endPoint: .trailing)
    }

    /// Angular gradient for circular strokes (e.g. the spinner arc).
    static var logoAngularGradient: AngularGradient {
        AngularGradient(colors: [.logoPurple, .logoPurpleLight, .logoCyan, .logoPurpleLight, .logoPurple], center: .center)
    }
}

// MARK: - Session phase (copilot-island SessionPhase, verbatim)

/// The current phase of the notch's agent session. Derived in ``NotchSessionStore`` from the
/// DeepAgent run state rather than a Copilot CLI event stream.
enum SessionPhase: Equatable {
    case idle
    case processing
    case runningTool(name: String)
    case waitingForApproval(toolName: String)
    case error(message: String)
    case ended(reason: String)
}

// MARK: - Chat history items (copilot-island, + a Mispher `.todos` case)

/// One rendered item in the notch chat. Mapped from a `MlxModelManager.ChatMessage` (and its
/// `AgentStep` timeline) in ``NotchSessionStore``.
struct ChatHistoryItem: Identifiable, Equatable {
    let id: String
    let type: ChatHistoryItemType

    init(id: String = UUID().uuidString, type: ChatHistoryItemType) {
        self.id = id
        self.type = type
    }
}

enum ChatHistoryItemType: Equatable {
    case user(String)
    /// Assistant answer; `streaming` is true while it's still being produced. The bubble renders as
    /// Markdown throughout (token bursts are coalesced to ~16 Hz upstream, so MarkdownUI re-parses
    /// only a few times a second), so it never pops from plain text to Markdown when the turn ends.
    case assistant(String, streaming: Bool)
    case toolCall(ToolCallItem)
    /// Reasoning text; `streaming` is true while it's still being produced (drives the "Thinking…"
    /// animated dots).
    case thinking(String, streaming: Bool)
    /// Mispher addition: the agent's to-do plan (copilot-island has no equivalent).
    case todos([NotchTodo])
}

/// A tool call in the chat history. `input` is already rendered for display (the agent timeline's
/// `key: value` form); `result` is the raw tool output (pretty-printed as JSON when it is JSON).
struct ToolCallItem: Equatable {
    let id: String
    let name: String
    let input: String
    var status: ToolStatus
    var result: String?
}

enum ToolStatus: Equatable {
    case running
    case success
    case error(String?)
}

/// A flattened, `Equatable` to-do row mapped from `MispherCore.TodoItem` (whose own type isn't
/// `Equatable`), so ``ChatHistoryItemType`` can synthesise equality.
struct NotchTodo: Equatable, Identifiable {
    let id: String
    let content: String
    let status: Status

    enum Status: Equatable { case pending, inProgress, completed }

    init(_ item: TodoItem) {
        id = item.id.uuidString
        content = item.content
        switch item.status {
        case .pending: status = .pending
        case .inProgress: status = .inProgress
        case .completed: status = .completed
        }
    }
}

// MARK: - Notch session (replaces copilot-island's HistoricalSession)

/// A conversation the notch can show. Mispher has a single live Ask thread (keyed by the Ask
/// selection id), so there's normally one of these; it stands in for copilot-island's multi-session
/// `HistoricalSession` list.
struct NotchSession: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    /// First line of the opening prompt, shown as the conversation's label in the session list.
    var preview: String?
    /// Time of the latest turn, shown as a relative "x min ago" stamp in the session list.
    var date: Date?

    static func == (lhs: NotchSession, rhs: NotchSession) -> Bool { lhs.id == rhs.id }
}
