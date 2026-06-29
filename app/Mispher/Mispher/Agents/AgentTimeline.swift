import DeepAgents
import Foundation

/// One entry in the agent's execution timeline, recorded in the order it happened: a
/// round's reasoning, a (non-todo) tool call, or a snapshot of the to-do plan. Rendering
/// these in sequence shows the model's actual flow — reason → tool → plan → reason → answer
/// — instead of grouping everything by type.
///
/// Lives in MispherCore (not the SwiftUI layer) because `MlxModelManager` records a timeline
/// on each chat message; the app's `AgentTimelineView` renders these.
public struct AgentStep: Identifiable, Sendable {
    public let id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public enum Kind: Sendable {
        /// A `<think>` reasoning block for one model round.
        case reasoning(String)
        /// A tool call and its result. `write_todos` is not represented here — it shows as a
        /// `.todos` checklist instead. `imageURL` is an optional image the tool produced (e.g. a
        /// screenshot), rendered as a thumbnail. `subagent` names the subagent a `task` delegated
        /// to; `output` accumulates streamed progress while running and holds the final result once
        /// `done`.
        case tool(
            name: String, input: String, output: String?, imageURL: URL? = nil,
            subagent: String? = nil, done: Bool = false
        )
        /// The to-do plan at the point a `write_todos` call updated it.
        case todos([TodoItem])
    }
}

/// Folds the agent's `AgentEvent` stream into an ordered `[AgentStep]` timeline plus the
/// still-streaming text of the current round and the final answer. Pure (no UI / actor
/// state) so it can be unit-tested and reused by both the main Ask view and the chat.
public struct AgentTimelineBuilder {
    /// Completed steps, in execution order.
    public private(set) var steps: [AgentStep] = []
    /// The current round's visible answer text as it streams.
    public private(set) var streamingText = ""
    /// The current round's chain-of-thought as it streams on the reasoning channel.
    public private(set) var streamingReasoning = ""
    /// The final answer (set once the last, tool-free round completes).
    public private(set) var answer = ""

    public init() {}

    private static let todosToolName = "write_todos"

    public mutating func consume(_ event: AgentEvent) {
        switch event {
        case .token(let chunk, _):
            streamingText += chunk

        case .reasoningToken(let chunk):
            streamingReasoning += chunk

        case .roundCompleted(let hadToolCalls):
            // Reasoning streams on its own channel now; also split any inline `<think>` still left in
            // the answer text (a model that inlines it) and merge the two.
            let parsed = ThinkingSplit.split(streamingText)
            var reasoningParts = [streamingReasoning, parsed.thinking ?? ""].filter { !$0.isEmpty }
            streamingText = ""
            streamingReasoning = ""
            if hadToolCalls {
                // A tool round's visible text is pre-tool reasoning; show it if nothing else streamed.
                if reasoningParts.isEmpty, !parsed.answer.isEmpty { reasoningParts.append(parsed.answer) }
                appendReasoning(reasoningParts.isEmpty ? nil : reasoningParts.joined(separator: "\n\n"))
            } else {
                appendReasoning(reasoningParts.isEmpty ? nil : reasoningParts.joined(separator: "\n\n"))
                answer = parsed.answer
            }

        case .toolStarted(let name, let input):
            guard name != Self.todosToolName else { break }
            steps.append(AgentStep(kind: .tool(name: name, input: input, output: nil)))

        case .toolProgress(let name, let subagent, let delta):
            appendToolProgress(name: name, subagent: subagent, delta: delta)

        case .toolCompleted(let name, let result, let imageURL, _):
            setToolOutput(name: name, output: result, imageURL: imageURL)

        case .toolFailed(let name, let error):
            setToolOutput(name: name, output: "⚠️ \(error)")

        case .todosUpdated(let todos):
            steps.append(AgentStep(kind: .todos(todos)))

        case .contextCompacted:
            break // the compaction note is surfaced by the chat view-model, not the timeline

        case .completed, .failed:
            break
        }
    }

    private mutating func appendReasoning(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        steps.append(AgentStep(kind: .reasoning(text)))
    }

    private mutating func setToolOutput(name: String, output: String, imageURL: URL? = nil) {
        guard name != Self.todosToolName else { return }
        guard
            let index = steps.lastIndex(where: {
                if case .tool(let n, _, _, _, _, let done) = $0.kind { return n == name && !done }
                return false
            }),
            case .tool(let n, let input, _, let existingImage, let subagent, _) = steps[index].kind
        else { return }
        steps[index].kind = .tool(
            name: n, input: input, output: output,
            imageURL: imageURL ?? existingImage, subagent: subagent, done: true
        )
    }

    /// Accumulate a still-running tool's streamed output and attach its subagent label. Matches the
    /// most recent not-yet-`done` step with this name; an empty `delta` only sets the label.
    private mutating func appendToolProgress(name: String, subagent: String?, delta: String) {
        guard name != Self.todosToolName else { return }
        guard
            let index = steps.lastIndex(where: {
                if case .tool(let n, _, _, _, _, let done) = $0.kind { return n == name && !done }
                return false
            }),
            case .tool(let n, let input, let output, let image, let existingSub, _) = steps[index].kind
        else { return }
        steps[index].kind = .tool(
            name: n, input: input,
            output: delta.isEmpty ? output : (output ?? "") + delta,
            imageURL: image, subagent: subagent ?? existingSub, done: false
        )
    }
}
