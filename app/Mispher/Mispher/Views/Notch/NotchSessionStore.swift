import Combine
import DeepAgents
import Foundation
import Observation
import SwiftUI

/// The notch's backend, replacing copilot-island's `SessionStore` (which read a Copilot-CLI socket +
/// `events.jsonl`). It exposes the same surface the ported notch views consume - `phase`,
/// `pendingApproval`, `history`, `sessionActive` - but derives it live from Mispher's on-device
/// DeepAgent (``MlxModelManager``) for the active Ask thread, and routes approve/deny through
/// `MlxModelManager`'s human-in-the-loop flow. It re-reads on every agent change via
/// `withObservationTracking`, then republishes for the (Combine-based) ported views.
@MainActor
final class NotchSessionStore: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var pendingApproval: ToolApprovalRequest?
    @Published private(set) var history: [ChatHistoryItem] = []
    @Published private(set) var sessionActive = false
    @Published private(set) var title = "Mispher"
    @Published private(set) var isCapturing = false
    /// The mic-pulse mode for the listening pill, mirroring the dictation overlay.
    @Published private(set) var capturePulse: MicPulseView.Mode = .idle
    @Published private(set) var isGenerating = false
    /// True while a manual compaction of the active conversation is running, for a menu indicator.
    @Published private(set) var isCompacting = false
    /// Readiness of the selected Ask model, driving the floating card's header status: whether the
    /// on-device model is loaded and ready to answer, still loading, not selected, or failed to load.
    @Published private(set) var modelReadiness: AskModelReadiness = .noModel
    /// The raw spoken words of the in-flight turn (empty until the first word lands), shown as a live
    /// user bubble while recording.
    @Published private(set) var liveTranscript = ""
    @Published private(set) var recentSessions: [NotchSession] = []
    /// Conversations with an unseen reply (drives the closed-notch "new message" dot). Cleared by the
    /// session list when tapped; Mispher has a single live thread, so this is usually empty.
    @Published var sessionsWithNewMessages: Set<String> = []

    private weak var viewModel: TranscriptionViewModel?
    private weak var mlx: MlxModelManager?
    /// The active Ask thread id (a catalog model id or a DeepAgent sentinel) - also the approval scope.
    private(set) var threadId: String?

    /// Wire the store to the shared models and begin tracking. Call once the app's view model and
    /// model manager exist.
    func bind(viewModel: TranscriptionViewModel, mlx: MlxModelManager) {
        self.viewModel = viewModel
        self.mlx = mlx
        refresh()
    }

    // MARK: - HITL

    func approve() {
        guard let id = threadId else { return }
        mlx?.resolveToolApproval(.approve, scope: id)
    }

    func deny() {
        guard let id = threadId else { return }
        mlx?.resolveToolApproval(.reject(message: nil), scope: id)
    }

    /// Send a typed message as the next turn (the keyboard counterpart to a spoken Ask), routed
    /// through the same multi-turn chat backend the voice flow uses.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = threadId, mlx?.isGenerating(id) != true else { return }
        Task { await viewModel?.askOverlayTurn(prompt: trimmed) }
    }

    /// Stop the in-flight turn (the stop button); the reply is kept where it halted.
    func cancel() {
        guard let id = threadId else { return }
        mlx?.cancelChat(id)
    }

    // MARK: - Menu actions

    func openInMainWindow() {
        guard let viewModel else { return }
        viewModel.bringToFront()
        viewModel.chatMode = true
        viewModel.dismissAskOverlay()
    }

    /// Compact the active conversation - summarize its older turns to free the context window (the
    /// manual companion to the automatic 85% trigger). A no-op while a turn is generating or another
    /// compaction is already running.
    func compactConversation() {
        guard let id = threadId, let mlx, !mlx.isGenerating(id), !isCompacting else { return }
        isCompacting = true
        Task { @MainActor [weak self] in
            await mlx.compactConversation(id)
            self?.isCompacting = false
            self?.refresh()
        }
    }

    /// Open the app's Settings window and stand the notch down (you're leaving the notch for the app).
    func openSettings() {
        guard let viewModel else { return }
        viewModel.openSettings()
        viewModel.dismissAskOverlay()
    }

    /// Start a brand-new saved conversation: stop any in-flight turn on the current one and drop its
    /// pending approval, then open a fresh thread (pinned to the current Ask model). The previous
    /// conversation stays saved in `~/.mispher` - it isn't cleared. `threadId` is updated synchronously
    /// so the chat view can switch to the empty thread immediately.
    func newSession() {
        if let id = threadId {
            mlx?.cancelChat(id)
            mlx?.resolveToolApproval(.reject(message: nil), scope: id)
        }
        if let model = viewModel?.askModelId, let newId = mlx?.startConversation(model: model) {
            threadId = newId
        }
        liveTranscript = ""
    }

    /// Open (resume) a saved conversation from the list - rebuilds its transcript from disk and makes
    /// it the active thread.
    func openConversation(_ session: NotchSession) {
        sessionsWithNewMessages.remove(session.id)
        Task { await viewModel?.resumeConversation(session.id) }
    }

    /// Whether an Ask model is selected (required to open a conversation) - gates the new-chat button.
    var hasAskModel: Bool { viewModel?.askModelId != nil }

    /// The readiness of the selected Ask model for the floating card's header dot. `idle` means a
    /// model is chosen but not resident yet (it loads on demand); `loading` covers download + warm-up.
    enum AskModelReadiness: Equatable { case noModel, idle, loading, ready, failed }

    /// Map the selected Ask model's live load state into ``AskModelReadiness`` (DeepAgent sentinels
    /// fold their two models via ``MlxModelManager/state(for:)``).
    private static func readiness(_ selection: String?, mlx: MlxModelManager) -> AskModelReadiness {
        guard let selection else { return .noModel }
        switch mlx.state(for: selection) {
        case .idle: return .idle
        case .loading: return .loading
        case .ready: return .ready
        case .failed: return .failed
        }
    }

    // MARK: - Observation

    /// Set while a coalesced refresh is already queued, so a burst of token-by-token changes
    /// schedules only one rebuild per window instead of one per token.
    private var refreshScheduled = false

    /// Recompute from the live agent state, then re-arm observation so the next change refreshes
    /// again (mirrors `RecordingOverlayController.track()`). Changes are coalesced via
    /// ``scheduleRefresh()`` rather than applied per-token: every streamed token mutates
    /// `MlxModelManager.transcripts`, and rebuilding `history` (plus the SwiftUI + MarkdownUI
    /// re-render it drives) on each one is what made streaming laggy. We still re-arm on every
    /// change, but batch the expensive rebuild to ~16 Hz.
    func refresh() {
        withObservationTracking { apply() } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    /// Re-run ``refresh()`` at most once per frame-ish window, capturing the latest agent state on
    /// the trailing edge (so the final token always lands) without thrashing on every token.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func apply() {
        guard let viewModel, let mlx else { return }
        // The notch only ever presents Ask. A non-Ask dictation/translate/rewrite capture shows its
        // own island (RecordingOverlayController) while the notch stands down, so it must NOT mark
        // the notch as "capturing" - that flips it into chat mode and leaves a stray conversation
        // view behind once the dictation island goes away. So the listening state is Ask-only.
        // Header readiness reflects the chosen Ask model's load state regardless of conversation
        // state, so it's current even before the first turn opens a thread.
        modelReadiness = Self.readiness(viewModel.askModelId, mlx: mlx)
        let askCapture = viewModel.activeIntent == .ask
        // Recording, or the brief finalizing window before the spoken prompt commits to the thread -
        // so the listening pill holds across that gap instead of flashing the empty chat.
        isCapturing = askCapture && (viewModel.isSessionActive || viewModel.isBusy)
        capturePulse = askCapture ? overlayPulse(viewModel.state) : .idle
        // The raw spoken words (not the "Listening…" placeholder), so the listening pill shows them.
        liveTranscript = askCapture ? (viewModel.partialText.isEmpty ? viewModel.finalText : viewModel.partialText) : ""
        sessionActive = viewModel.askOverlaySessionActive

        // The list shows every saved conversation (newest activity first); the active one drives the
        // live phase / history / approval below.
        recentSessions = mlx.conversationList.map {
            NotchSession(id: $0.id, title: $0.title, subtitle: nil, preview: $0.title, date: $0.updatedAt)
        }

        let id = mlx.activeConversationId
        threadId = id

        guard let id else {
            phase = .idle
            pendingApproval = nil
            history = []
            isGenerating = false
            return
        }

        let messages = mlx.transcript(for: id)
        let approval = mlx.pendingToolApproval(for: id)
        let generating = mlx.isGenerating(id)

        isGenerating = generating
        pendingApproval = approval
        history = Self.makeHistory(messages, generating: generating)

        if let approval {
            phase = .waitingForApproval(toolName: approval.toolName)
        } else if let lastModel = messages.last(where: { $0.role == .model }), lastModel.isError {
            phase = .error(message: lastModel.text)
        } else if generating {
            phase = Self.runningToolName(messages).map { .runningTool(name: $0) } ?? .processing
        } else {
            phase = .idle
        }
    }

    // MARK: - Mapping

    /// Expand each chat message (and its `AgentStep` timeline) into the notch's history items, the way
    /// copilot-island's `ConversationParser` expanded `events.jsonl`.
    private static func makeHistory(_ messages: [MlxModelManager.ChatMessage], generating: Bool) -> [ChatHistoryItem] {
        var items: [ChatHistoryItem] = []
        for message in messages {
            switch message.role {
            case .user:
                if !message.text.isEmpty {
                    items.append(ChatHistoryItem(id: message.id.uuidString, type: .user(message.text)))
                }
            case .model:
                // Only the final model turn can still be streaming; earlier turns are complete.
                let isLast = message.id == messages.last?.id
                for step in message.timeline {
                    let stepID = "\(message.id.uuidString)-\(step.id.uuidString)"
                    switch step.kind {
                    case .reasoning(let text):
                        // A completed round's reasoning - never streaming.
                        items.append(ChatHistoryItem(id: stepID, type: .thinking(text, streaming: false)))
                    case .tool(let name, let input, let output, _, _, let done):
                        let tool = ToolCallItem(
                            id: step.id.uuidString,
                            name: name,
                            input: input,
                            status: Self.toolStatus(output: output, done: done),
                            result: done ? output : nil
                        )
                        items.append(ChatHistoryItem(id: stepID, type: .toolCall(tool)))
                    case .todos(let todos):
                        items.append(ChatHistoryItem(id: stepID, type: .todos(todos.map(NotchTodo.init))))
                    }
                }
                // Split the (possibly still-streaming) reply so a live `<think>…</think>` block shows
                // as collapsible reasoning rather than raw tags in the answer.
                let split = ThinkingSplit.split(message.text)
                if let thinking = split.thinking {
                    // Live reasoning streams while the answer hasn't started yet.
                    let streaming = generating && isLast && split.answer.isEmpty
                    items.append(ChatHistoryItem(
                        id: "\(message.id.uuidString)-think", type: .thinking(thinking, streaming: streaming)
                    ))
                }
                // The current round's reasoning arrives on its own channel (not inline in `text`), so it
                // isn't in `timeline` until the round completes. Show it streaming live until then.
                if isLast, generating, !message.liveReasoning.isEmpty {
                    items.append(ChatHistoryItem(
                        id: "\(message.id.uuidString)-live-think", type: .thinking(message.liveReasoning, streaming: true)
                    ))
                }
                if !split.answer.isEmpty {
                    items.append(ChatHistoryItem(
                        id: message.id.uuidString, type: .assistant(split.answer, streaming: generating && isLast)
                    ))
                }
            }
        }
        return items
    }

    /// A finished tool's status. Both failure shapes count as errors: `⚠️ …` (a thrown tool error)
    /// and the `{"error": …}` feedback used for runtime errors *and* user-rejected calls - otherwise
    /// a rejected call rendered as "Success".
    private static func toolStatus(output: String?, done: Bool) -> ToolStatus {
        guard done else { return .running }
        guard let output, !output.isEmpty else { return .success }
        if output.hasPrefix("⚠️") { return .error(output) }
        if let message = errorMessage(in: output) { return .error(message) }
        return .success
    }

    /// The `error` string from a `{"error": …}` tool result, or nil if the output isn't that shape.
    private static func errorMessage(in output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["error"] as? String, !message.isEmpty
        else { return nil }
        return message
    }

    /// The name of the most recent still-running tool call in the latest model turn, if any (so the
    /// phase can read `.runningTool` rather than a bare `.processing`).
    private static func runningToolName(_ messages: [MlxModelManager.ChatMessage]) -> String? {
        guard let last = messages.last(where: { $0.role == .model }) else { return nil }
        for step in last.timeline.reversed() {
            if case .tool(let name, _, _, _, _, let done) = step.kind, !done { return name }
        }
        return nil
    }
}
