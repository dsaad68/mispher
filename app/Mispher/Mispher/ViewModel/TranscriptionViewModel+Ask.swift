import DeepAgents

/// Ask / DeepAgent: turning the spoken transcript into a model answer. Split out of
/// ``TranscriptionViewModel`` so the main file stays within the length limit. ``askLocalModel()``
/// powers the single-turn HUD answer (notch pill / main window); ``askOverlayTurn(prompt:)`` powers
/// the multi-turn conversation shown in the roomier compact overlays (floating / dynamic island),
/// routed through the same chat backend the HUD chat uses so the overlay and HUD chat stay in sync.
@MainActor
extension TranscriptionViewModel {
    /// Ask activation focus policy: a roomier overlay form runs Ask as a voice conversation in the
    /// overlay (keep the user's app focused, mark the sticky session); the notch pill and main
    /// window keep the single-turn HUD Ask, which brings Mispher forward (its answer shows there).
    func activateAsk(fresh: Bool) {
        // A fresh Ask press starts a brand-new saved conversation (a `~/.mispher` thread pinned to the
        // current Ask model); the continue shortcut keeps appending to the active one, starting the
        // first if none exists yet.
        if let model = askModelId, fresh || mlxModels?.activeConversationId == nil {
            mlxModels?.startConversation(model: model)
        }
        if askOverlaySupported { askOverlaySessionActive = true } else { bringToFront() }
    }

    /// Whether the dial's Ask slice should offer **Continue**: true when there's an active `~/.mispher`
    /// Ask thread to append to (``RecordIntent/askContinue``). With none, the dial shows a single Ask
    /// slice that starts fresh -- "continuing" nothing would just start a new conversation anyway.
    var hasResumableAskConversation: Bool { mlxModels?.activeConversationId != nil }

    /// Resume a saved conversation from a list: make it the active thread (rebuilding its transcript
    /// from disk). Ask is DeepAgent-only, so there's no per-conversation model to reselect.
    ///
    /// `activateOverlay` marks the Ask overlay session active so the notch / floating card re-shows the
    /// conversation - the right thing when resuming *from* the overlay's own session list. The main chat
    /// window's sidebar passes `false`: it switches the conversation in place and must NOT pop the
    /// overlay over the main window (which read as a stray "listening" / Ask card with no recording).
    ///
    /// The transcript is rebuilt from disk *before* the active thread is switched, so the notch flips
    /// straight to the finished conversation in a single update. Switching first and rebuilding async
    /// (the old order) left the notch showing the previous conversation - or an empty "Listening…"
    /// chat - until a later refresh that didn't reliably fire, so it looked stuck until you hit Esc.
    func resumeConversation(_ id: String, activateOverlay: Bool = true) async {
        guard let mlx = mlxModels else { return }
        await mlx.resume(id)
        mlx.activateConversation(id)
        if activateOverlay, askOverlaySupported { askOverlaySessionActive = true }
    }

    /// True when a fresh Ask press should be ignored because the overlay conversation's current
    /// turn is still answering -- the chat backend guards on `generating`, so a new turn would be
    /// dropped after recording. Only blocks a brand-new session (an in-progress capture is fine).
    func isAskTurnBusy(_ intent: RecordIntent) -> Bool {
        guard intent == .ask, !isSessionActive, askOverlaySessionActive,
              let id = mlxModels?.activeConversationId else { return false }
        return mlxModels?.isGenerating(id) == true
    }

    // MARK: - Single-turn HUD answer

    /// Send the finalized transcript to the selected on-device model and stream
    /// its reply into `askReplyText` beneath the transcript. Loads the model on
    /// demand. Best-effort: failures surface as a status hint and leave whatever
    /// streamed so far intact.
    func askLocalModel() async {
        let prompt = finalText
        guard !prompt.isEmpty, let modelId = askModelId, let mlx = mlxModels else { return }

        askReplyText = ""
        askTimeline = []
        askStreamingText = ""
        isAsking = true
        statusMessage = "Asking \(askSelectionLabel ?? "model")…"
        defer { isAsking = false }

        // Fold the event stream into an ordered reasoning/tool/todo timeline (plus the live
        // streaming text and the final answer), so the UI shows the model's actual flow.
        var builder = AgentTimelineBuilder()
        let ok = await mlx.askAgent(prompt, modelId: modelId) { [weak self] event in
            // A new session may have started while streaming — don't clobber it.
            guard let self, finalText == prompt, !self.isSessionActive else { return }
            builder.consume(event)
            askTimeline = builder.steps
            askStreamingText = builder.streamingText
            askReplyText = builder.answer
        }

        guard finalText == prompt, !isSessionActive else { return }
        if !ok && askReplyText.isEmpty {
            statusMessage = "Couldn't run \(askSelectionLabel ?? "the on-device model")."
        } else {
            statusMessage = selectedModel.readyMessage
        }
    }

    // MARK: - Multi-turn overlay conversation

    /// Add a turn to the voice-driven Ask/DeepAgent conversation shown in a compact overlay.
    /// Routes the spoken transcript into the same multi-turn chat backend the HUD chat uses
    /// (``MlxModelManager/sendAgent(_:prompt:imageURL:)`` / ``sendDeepAgent(_:prompt:)``, keyed by
    /// the Ask selection id), so the overlay and the HUD chat are one conversation and follow-ups
    /// keep prior context. The overlay view renders the latest exchange from that thread directly.
    func askOverlayTurn(prompt: String) async {
        guard let modelId = askModelId, let mlx = mlxModels else { return }
        // Append to the active conversation (a `~/.mispher` thread), not the model id, so the exchange
        // is saved and resumable. Start one lazily if the activation path didn't.
        let thread = mlx.activeConversationId ?? mlx.startConversation(model: modelId)
        statusMessage = "Asking \(askSelectionLabel ?? "model")…"
        if let variant = DeepAgentVariant.variant(for: modelId) {
            await mlx.sendDeepAgent(variant, prompt: prompt, threadId: thread)
        }
        await mlx.refreshConversations()
        statusMessage = selectedModel.readyMessage
    }

    /// Dismiss the compact Ask overlay conversation: clear the sticky session flag (which hides the
    /// overlay) and reject any pending tool approval so a suspended DeepAgent run unblocks. The
    /// conversation is left intact in the shared chat thread, so re-opening Ask or the HUD chat
    /// continues it. The thread key is the Ask selection id, which is also the approval scope.
    func dismissAskOverlay() {
        guard askOverlaySessionActive else { return }
        askOverlaySessionActive = false
        if let id = mlxModels?.activeConversationId {
            mlxModels?.resolveToolApproval(.reject(message: "Dismissed."), scope: id)
        }
    }

    /// Human-friendly label for an agent tool name, for the answer's tool affordance.
    static func friendlyToolName(_ name: String) -> String {
        switch name {
        case "read_clipboard": return "clipboard read"
        case "write_clipboard": return "clipboard write"
        case "write_todos": return "to-do list"
        case "current_datetime": return "date & time"
        case "calculator": return "calculator"
        case "take_screenshot": return "screenshot"
        case "ls": return "file list"
        case "read_file": return "file read"
        case "write_file": return "file write"
        case "edit_file": return "file edit"
        default: return name
        }
    }
}
