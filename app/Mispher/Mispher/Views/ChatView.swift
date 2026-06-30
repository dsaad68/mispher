import AppKit
import DeepAgents
import DeepAgentsMLX
import SwiftUI
import UniformTypeIdentifiers

/// The app's primary type-only chat, hosted in ``ChatWindowView``. It reuses the header's Ask model
/// picker as its selector — the Ask selection is the chat target — so there's a single selector and
/// the choice (and its on-demand load) is shared with the spoken-Ask flow. A catalog model
/// chats directly (optionally through the tool-using agent); a DeepAgent selection runs the
/// full deep agent — planner, subagents, and the real-disk filesystem behind the same
/// human-in-the-loop approval card as the Ask flow.
struct ChatView: View {
    @Environment(MlxModelManager.self) private var mlx
    @Environment(TranscriptionViewModel.self) private var vm

    @State private var prompt = ""
    @State private var imageURL: URL?
    /// The composer text captured when the mic started, so a dictation streams in *after* whatever
    /// was already typed instead of replacing it.
    @State private var dictationBaseline = ""
    @FocusState private var inputFocused: Bool

    /// What the chat is pointed at — a catalog model or a DeepAgent variant — under one
    /// readiness / transcript key so the body has a single code path. The key is the Ask
    /// selection id itself (a model id, or the variant's sentinel id).
    private struct ChatTarget {
        let id: String
        let displayName: String
        /// Whether the target can take an attached image. Vision catalog models only:
        /// the DeepAgent planner is blind and captures screenshots itself.
        let isVision: Bool
        let model: MlxModel?
        let variant: DeepAgentVariant?
    }

    /// The current chat target: the on-device DeepAgent when Ask is enabled (nil when off). Ask is
    /// DeepAgent-only, so chat always runs the DeepAgent; its planner + vision come from Ask settings.
    private var target: ChatTarget? {
        guard let id = vm.askModelId, let variant = DeepAgentVariant.variant(for: id) else { return nil }
        return ChatTarget(
            id: variant.id, displayName: variant.label, isVision: false,
            model: nil, variant: variant
        )
    }

    var body: some View {
        // No sub-header: the target's name is in the toolbar's Ask picker and the tools /
        // clear controls live up there too (next to the chat toggle).
        VStack(spacing: 0) {
            conversation(for: target)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: vm.askModelId) { _, _ in
            // A switch to a target that can't take an image drops a stale attachment.
            if !(target?.isVision ?? false) { imageURL = nil }
        }
    }

    // MARK: Body states

    @ViewBuilder private func conversation(for target: ChatTarget?) -> some View {
        if let target {
            switch mlx.state(for: target.id) {
            case .ready:
                transcript(target)
                inputBar(target)
            case .loading(let fraction):
                loadingState(target.displayName, fraction)
            case .idle:
                // Picked but warming hasn't kicked in yet (entering chat warms it) — show
                // the same indeterminate state so input stays gated until ready.
                loadingState(target.displayName, nil)
            case .failed(let message):
                failedState(message)
            }
        } else {
            emptyState
        }
    }

    private func loadingState(_ name: String, _ fraction: Double?) -> some View {
        VStack(spacing: 10) {
            if let fraction {
                ProgressView(value: fraction).frame(width: 160).tint(Palette.accent)
                Text("Downloading \(name) · \(Int(fraction * 100))%")
            } else {
                ProgressView().controlSize(.small).tint(Palette.accent)
                Text("Loading \(name)…")
            }
        }
        .font(.sans(12))
        .foregroundStyle(Palette.fg2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(Palette.recRed)
            Text(message)
                .font(.sans(11.5))
                .foregroundStyle(Palette.fg2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { mlx.setAskModel(vm.askModelId) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Try again")
                        .font(.sans(11.5, weight: .medium))
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22))
                .foregroundStyle(Palette.fg3)
            Text("Enable Ask to start chatting")
                .font(.sans(12))
                .foregroundStyle(Palette.fg2)
                .multilineTextAlignment(.center)
            Text("Turn on Ask in the Ask settings tab to chat with the on-device DeepAgent.")
                .font(.sans(10.5))
                .foregroundStyle(Palette.fg3)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: Transcript + input

    private func transcript(_ target: ChatTarget) -> some View {
        // The visible thread is the active saved conversation (so the sidebar can swap conversations);
        // before any conversation exists it falls back to the target's id (the DeepAgent sentinel).
        let threadID = mlx.activeConversationId ?? target.id
        let messages = mlx.transcript(for: threadID)
        let generating = mlx.isGenerating(threadID)
        let awaitingFirstToken = generating
            && (messages.last.map {
                $0.role == .model && $0.text.isEmpty && $0.timeline.isEmpty
            } ?? false)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { message in
                        if !(message.role == .model && message.text.isEmpty
                            && message.timeline.isEmpty) {
                            ChatBubble(
                                message: message,
                                streaming: generating && message.id == messages.last?.id
                            )
                        }
                    }
                    // A gated tool call waiting on the user (the deep agent's real-disk
                    // filesystem): this run is suspended until they decide, so show the
                    // same approval card as the Ask flow.
                    if let approval = mlx.pendingToolApproval(for: threadID) {
                        ToolApprovalCard(
                            request: approval,
                            approve: { mlx.resolveToolApproval(.approve, scope: threadID) },
                            deny: { mlx.resolveToolApproval(.reject(message: nil), scope: threadID) }
                        )
                        .padding(.vertical, 2)
                    }
                    if awaitingFirstToken {
                        ThinkingIndicator()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: messages.last?.text) { _, _ in scrollToBottom(proxy) }
            .onChange(of: mlx.isGenerating(threadID)) { _, _ in scrollToBottom(proxy) }
            .onChange(of: mlx.pendingToolApproval(for: threadID)?.id) { _, _ in scrollToBottom(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func inputBar(_ target: ChatTarget) -> some View {
        VStack(spacing: 6) {
            if target.isVision, let imageURL {
                HStack(spacing: 6) {
                    Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(Palette.accent)
                    Text(imageURL.lastPathComponent).font(.sans(10)).foregroundStyle(Palette.fg2).lineLimit(1)
                    Button { self.imageURL = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.fg3)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .center, spacing: 6) {
                if target.isVision {
                    Button(action: chooseImage) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Palette.fg2)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Attach image")
                }
                TextField("Message…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .font(.sans(15))
                    .foregroundStyle(Palette.fg)
                    .lineLimit(1 ... 4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                    .onSubmit { send(target) }
                micButton
                Button { send(target) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(canSend(target) ? Palette.accent : Palette.fg3)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend(target))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.glassFill.opacity(0.3))
        .onChange(of: vm.partialText) { _, partial in
            // Stream the live transcript into the field while dictating into the composer.
            if vm.composerDictationActive, vm.isSessionActive { prompt = composed(partial) }
        }
        .onChange(of: vm.composerDictationActive) { _, active in
            // Dictation finished: commit the finalized (post-cleanup) transcript and refocus for edits.
            if !active {
                prompt = composed(vm.finalText)
                inputFocused = true
            }
        }
    }

    /// Composer mic: dictate speech straight into the message field (editable, then send) instead of
    /// typing. Toggles a `.transcription` capture flagged for the composer; the live transcript streams
    /// in via the `onChange` handlers above. Disabled while another (hotkey) session is recording.
    private var micButton: some View {
        let dictating = vm.composerDictationActive
        return Button {
            if dictating {
                vm.stopComposerDictation()
            } else {
                dictationBaseline = prompt
                vm.startComposerDictation()
            }
        } label: {
            Image(systemName: dictating ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: dictating ? 18 : 14, weight: .medium))
                .foregroundStyle(dictating ? Palette.recRed : Palette.fg2)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(vm.isSessionActive && !dictating)
        .help(dictating ? "Stop dictation" : "Dictate a message")
    }

    /// Join the pre-mic baseline text with the dictated `text`, inserting one separating space when the
    /// baseline doesn't already end in whitespace, so dictation flows after whatever was already typed.
    private func composed(_ text: String) -> String {
        guard !dictationBaseline.isEmpty, dictationBaseline.last?.isWhitespace == false, !text.isEmpty
        else { return dictationBaseline + text }
        return dictationBaseline + " " + text
    }

    private func canSend(_ target: ChatTarget) -> Bool {
        let threadID = mlx.activeConversationId ?? target.id
        return !mlx.isGenerating(threadID) && !vm.composerDictationActive
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ target: ChatTarget) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID = mlx.activeConversationId ?? target.id
        guard !text.isEmpty, !mlx.isGenerating(threadID) else { return }
        let image = imageURL
        let agentMode = vm.chatUseTools
        prompt = ""
        imageURL = nil
        Task {
            // Append to the active saved conversation, starting one lazily so the first message of a
            // fresh chat is persisted and resumable - not pinned to the sentinel thread.
            let thread = mlx.activeConversationId ?? mlx.startConversation(model: target.id)
            if let variant = target.variant {
                // The deep agent IS its tools — the plain-chat toggle doesn't apply.
                await mlx.sendDeepAgent(variant, prompt: text, threadId: thread)
            } else if let model = target.model, agentMode {
                await mlx.sendAgent(model, prompt: text, imageURL: image)
            } else if let model = target.model {
                await mlx.send(model, prompt: text, imageURL: image)
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { imageURL = panel.url }
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let message: MlxModelManager.ChatMessage
    /// Whether this reply is still generating (keeps its "Steps" group open live).
    var streaming = false
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 28) }
            bubble
            // Agent replies cap at a readable column width (see `modelBubble`); the rest is gutter.
            if !isUser { Spacer(minLength: 4) }
        }
    }

    @ViewBuilder private var bubble: some View {
        if isUser {
            Text(message.text)
                .font(.sans(15))
                .foregroundStyle(Palette.bgDeep)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.accent))
        } else if message.isError {
            Text(message.text)
                .font(.sans(15))
                .foregroundStyle(Palette.recRed)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06)))
        } else {
            modelBubble
        }
    }

    /// An agent reply: the reasoning / tool / to-do timeline in execution order, then the
    /// answer (its `<think>` shown collapsibly, the rest as markdown). Plain replies have an
    /// empty timeline and just show the answer.
    private var modelBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.timeline.isEmpty {
                AgentTimelineView(steps: message.timeline, streaming: streaming)
            }
            if !message.text.isEmpty {
                ModelMessageView(text: message.text)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}
