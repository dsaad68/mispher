import DeepAgents
import DeepAgentsMLX
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Loads, holds, and chats with on-device MLX models in-process via `mlx-swift-lm`.
/// Each model the user turns on in Settings is downloaded on first use from the
/// Hugging Face Hub and kept resident; turning it off frees it. Several can run at
/// once (memory permitting). Also backs the Translate→English pass. Independent of
/// the llama.cpp server used for Qwen ASR.
@MainActor
@Observable
public final class MlxModelManager {
    public init() {}

    public enum LoadState: Sendable, Equatable {
        case idle
        /// Loading — download fraction if known, `nil` while preparing weights.
        case loading(Double?)
        case ready
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .idle, .failed: return false
            case .loading, .ready: return true
            }
        }
    }

    /// On-disk download status for a model's files in the HF cache — independent of whether
    /// it's currently loaded into memory (``LoadState``). Mirrors the ASR side's download
    /// states so the Local-models settings can offer Download / Delete like ASR Models.
    public enum DiskState: Sendable, Equatable {
        case unknown // not yet checked
        case notDownloaded
        case downloading(Double?)
        case downloaded
        case failed(String)

        public var isDownloaded: Bool { if case .downloaded = self { return true } else { return false } }
        public var isDownloading: Bool { if case .downloading = self { return true } else { return false } }
    }

    /// One line in a model's chat transcript. `text` grows as the reply streams in.
    public struct ChatMessage: Identifiable, Sendable {
        public enum Role: Sendable { case user, model }
        public let id = UUID()
        /// When this turn was added - used for the notch session list's "x min ago" stamp.
        public let createdAt = Date()
        public let role: Role
        public var text: String
        public var isError = false
        /// The agent's reasoning / tool / to-do steps in execution order (model replies
        /// routed through the ReAct agent). Empty for plain replies and user turns.
        public var timeline: [AgentStep] = []
        /// The current round's chain-of-thought *as it streams*, before it's committed to `timeline`
        /// as a `.reasoning` step on round completion. Lets the UI show live reasoning (the reasoning
        /// arrives on its own channel, not inline in `text`). Empty once not generating.
        public var liveReasoning = ""
    }

    private enum StreamEvent: Sendable {
        case delta(String)
        case failed(String)
    }

    private(set) var states: [String: LoadState] = [:]
    /// Per-model chat transcript (keyed by model id), shown in the chat sidebar.
    private(set) var transcripts: [String: [ChatMessage]] = [:]
    /// Model ids with a reply currently generating.
    private(set) var generating: Set<String> = []
    /// Thread ids whose conversation is currently being compacted (manual `/compact` equivalent), so
    /// the chat UI can show a "Compacting context…" indicator.
    private(set) var isSummarizing: Set<String> = []
    /// In-flight chat run tasks by thread id, so a turn can be cancelled (the stop button). Cancelling
    /// propagates into MLXLMCommon's token loop (it checks `Task.isCancelled`), stopping generation.
    @ObservationIgnored private var chatRunTasks: [String: Task<Void, Never>] = [:]
    // Internal (not private) so the deep-agent idle layer in `MlxModelManager+DeepAgentIdle.swift`
    // can read them; otherwise treat as private to this type.
    var containers: [String: ModelContainer] = [:]
    var loadTasks: [String: Task<Void, Never>] = [:]
    /// On-disk download state per model id (parallels the in-memory `states`).
    private(set) var diskStates: [String: DiskState] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    /// Who currently needs each model resident. A model is freed (and its GPU
    /// memory reclaimed) only when this set empties — so switching the Ask or
    /// translation model releases the old one, while a model you turned on in
    /// Settings (or one a second feature still uses) stays put.
    var owners: [String: Set<Owner>] = [:]
    /// The model id currently bound to the main-view Ask flow (also the HUD chat model).
    var currentAskId: String?
    /// The model id currently bound to the Translate pass.
    private var currentTranslationId: String?
    /// The model id currently bound to the dictation cleanup pass.
    private var currentCleanupId: String?

    /// The user's saved Ask conversations in `~/.mispher` (one JSONL each). It doubles as the agent's
    /// thread-scoped checkpointer - keyed by conversation id - so the same file that lists and shows a
    /// conversation also restores the agent's context on resume.
    let conversations = ConversationStore()

    /// The Ask conversation currently shown / appended to (a ``ConversationStore`` id). The chat
    /// surfaces key their transcript, in-flight state, and approval scope on this. `nil` before the
    /// first Ask conversation of the session is started.
    private(set) var activeConversationId: String?

    /// The saved conversations for the list UI, newest activity first. Refreshed from
    /// ``conversations`` after each turn / create / switch / delete (and at launch).
    private(set) var conversationList: [ConversationMeta] = []

    /// The MCP servers + tool activation/approval policy the deep agent should use, pushed from
    /// the view model (``setAgentToolConfig(mcpServers:policy:)``) so they're current at run time.
    @ObservationIgnored private var mcpServers: [MCPServerConfig] = []
    @ObservationIgnored private var agentToolPolicy = AgentToolPolicy()
    /// The reused MCP client - it holds persistent sessions and live stdio subprocesses, so it
    /// must outlive a single run. Rebuilt only when the enabled-server set changes (keyed by its
    /// hash) and reaped on ``teardownMCP()``.
    @ObservationIgnored private var mcpClient: MultiServerMCPClient?
    @ObservationIgnored private var mcpClientKey: Int?
    /// The tools the warm client last loaded, namespaced `server__tool` - the single source of
    /// truth for what the agent can call. Observed, so the MCP Servers tab reflects this live
    /// connection directly instead of opening its own probe. Updated on every warm / agent build.
    private(set) var mcpWarmTools: [any AgentTool] = []
    /// True while ``warmMCP()`` is connecting, so the UI can show a refresh spinner.
    private(set) var mcpWarming = false

    /// Tool calls awaiting the user's approve / deny decision, keyed by run scope (a chat
    /// thread id, or ``askApprovalScope`` for the single-turn Ask flow). The deep agent's
    /// `HumanInTheLoopMiddleware` suspends its run inside ``requestToolApproval(_:scope:)``
    /// until the matching approval card resolves it. Scoping keeps two in-flight runs (e.g.
    /// the Ask flow and a HUD chat) from rejecting each other's pending approval; read a
    /// scope's request with ``pendingToolApproval(for:)``.
    private(set) var pendingToolApprovals: [String: ToolApprovalRequest] = [:]
    @ObservationIgnored
    private var toolApprovalContinuations: [String: CheckedContinuation<ToolApprovalDecision, Never>] = [:]
    /// The run scope for the single-turn Ask flow, which has no chat-thread id of its own.
    /// Distinct from any model / DeepAgent-variant id, so it never collides with a chat thread.
    public static let askApprovalScope = "mispher.ask.approval"

    /// The tool call awaiting approval for `scope` (a chat thread id, or ``askApprovalScope``),
    /// or nil when that run has nothing pending.
    public func pendingToolApproval(for scope: String) -> ToolApprovalRequest? {
        pendingToolApprovals[scope]
    }

    /// A reason a model is being kept resident. `*Run` owners are held only for the duration of
    /// an in-flight call, so a warmed owner being released mid-run can't unload the model.
    enum Owner: Hashable, Sendable { case manual, ask, translation, translationRun, cleanup, cleanupRun, rewrite }

    // The Ask picker's "DeepAgent" entry is a sentinel selection (not a catalog model id); see
    // `DeepAgentVariant`. Its planner + vision models are chosen in the Ask settings tab and managed
    // by the idle layer (warmed on selection, freed after an idle timeout), not pinned under `.ask`.

    public func state(for model: MlxModel) -> LoadState { states[model.id] ?? .idle }
    func isOn(_ model: MlxModel) -> Bool { state(for: model).isActive }

    /// Load state for an Ask-picker selection — the chat surface's readiness gate. A DeepAgent
    /// sentinel combines its two models' states: failed if either failed, loading while either
    /// is still loading (showing the furthest-behind known fraction), ready only when both are.
    /// Any other selection is just that model's own state.
    public func state(for selection: String) -> LoadState {
        var fractions: [Double?] = []
        var anyIdle = false
        for id in askModelIDs(for: selection) {
            switch states[id] ?? .idle {
            case .failed(let message): return .failed(message)
            case .loading(let fraction): fractions.append(fraction)
            case .idle: anyIdle = true
            case .ready: break
            }
        }
        if !fractions.isEmpty {
            let known = fractions.compactMap { $0 }
            return .loading(known.count == fractions.count ? known.min() : nil)
        }
        return anyIdle ? .idle : .ready
    }

    /// Models that are loaded and ready to chat with.
    var readyModels: [MlxModel] {
        MlxModel.catalog.filter { if case .ready = state(for: $0) { return true } else { return false } }
    }

    public func transcript(for model: MlxModel) -> [ChatMessage] { transcript(for: model.id) }
    public func isGenerating(_ model: MlxModel) -> Bool { isGenerating(model.id) }

    /// Transcript / in-flight state by chat-thread key: a catalog model id, or a DeepAgent
    /// sentinel (the HUD chat passes its Ask selection id straight through for both).
    public func transcript(for id: String) -> [ChatMessage] { transcripts[id] ?? [] }
    public func isGenerating(_ id: String) -> Bool { generating.contains(id) }
    /// Whether `id`'s conversation is mid-compaction, for the "Compacting context…" indicator.
    public func isSummarizing(_ id: String) -> Bool { isSummarizing.contains(id) }

    func toggle(_ model: MlxModel) {
        if isOn(model) {
            // Explicit "off" in Settings stops the model and frees its memory,
            // whoever else was using it (Ask/translation reload on demand).
            owners[model.id] = nil
            unload(model)
        } else {
            retain(model.id, by: .manual)
        }
    }

    // MARK: - Residency (reference-counted)

    /// Mark `id` as needed by `owner`, loading it if it isn't resident yet.
    private func retain(_ id: String, by owner: Owner) {
        owners[id, default: []].insert(owner)
        if containers[id] == nil, let model = MlxModel.catalog.first(where: { $0.id == id }) {
            load(model)
        }
    }

    /// Drop `owner`'s claim on `id`; free the model once nothing needs it.
    private func release(_ id: String, by owner: Owner) {
        guard owners[id]?.contains(owner) == true else { return }
        owners[id]?.remove(owner)
        if owners[id]?.isEmpty ?? true {
            owners[id] = nil
            if let model = MlxModel.catalog.first(where: { $0.id == id }) { unload(model) }
        }
    }

    /// Resolve an Ask selection to the real catalog model id(s) whose load state gates its readiness.
    /// The deep agent sentinel maps to its (user-chosen) planner only - the vision model loads lazily
    /// on first use, so it's deliberately not part of the readiness/residency set - and any other
    /// selection is itself. The deep agent's own residency is run by the idle layer (see
    /// ``setDeepAgentConfig(planner:vision:plannerIdleMinutes:visionIdleMinutes:)`` / ``beginUse(_:)``).
    private func askModelIDs(for selection: String) -> [String] {
        DeepAgentVariant.variant(for: selection) != nil ? [deepAgentPlannerID] : [selection]
    }

    /// Point the Ask flow at `id` (nil turns it off): releases the previous Ask model — freeing it
    /// unless something else still needs it — and warms up the new one. Called when the user changes
    /// the main-view Ask model.
    public func setAskModel(_ id: String?) {
        if currentAskId == id {
            if let id { warmAsk(id) } // ensure warm (idempotent)
            return
        }
        if let old = currentAskId { coolAsk(old) }
        currentAskId = id
        if let id { warmAsk(id) }
    }

    /// Warm the model(s) an Ask selection needs. A plain catalog model is pinned resident under the
    /// `.ask` owner; the deep agent's planner is instead handed to the idle layer (loaded now, freed
    /// after its idle timeout), and its vision model is left to load lazily on first use.
    private func warmAsk(_ id: String) {
        if DeepAgentVariant.variant(for: id) != nil {
            prewarmIdle(deepAgentPlannerID, idleMinutes: plannerIdleMinutes)
        } else {
            retain(id, by: .ask)
        }
    }

    /// Release an Ask selection's warm models. A plain model drops its `.ask` pin; the deep agent's
    /// idle-managed planner + vision are unloaded now (unless another owner still needs them).
    private func coolAsk(_ id: String) {
        if DeepAgentVariant.variant(for: id) != nil {
            coolIdle(deepAgentPlannerID)
            coolIdle(deepAgentVisionID)
        } else {
            release(id, by: .ask)
        }
    }

    /// Point the translation pass at `id` (nil turns it off): releases the previous
    /// translation model — freeing it unless something else still needs it — and warms
    /// up the new one. Mirrors ``setAskModel(_:)``; called when translation is toggled
    /// or its model is changed.
    public func setTranslationModel(_ id: String?) {
        if currentTranslationId == id {
            if let id { retain(id, by: .translation) } // already current — ensure warm (idempotent)
            return
        }
        if let old = currentTranslationId { release(old, by: .translation) }
        currentTranslationId = id
        if let id { retain(id, by: .translation) }
    }

    /// Point the dictation-cleanup pass at `id` (nil turns it off): releases the previous
    /// cleanup model — freeing it unless something else still needs it — and warms up the
    /// new one. Mirrors ``setTranslationModel(_:)``; called when AI cleanup is toggled or
    /// its model changes.
    public func setCleanupModel(_ id: String?) {
        if currentCleanupId == id {
            if let id { retain(id, by: .cleanup) } // already current — ensure warm (idempotent)
            return
        }
        if let old = currentCleanupId { release(old, by: .cleanup) }
        currentCleanupId = id
        if let id { retain(id, by: .cleanup) }
    }

    /// Begin loading `model` (download if needed) and keep it resident when ready.
    func load(_ model: MlxModel) {
        guard loadTasks[model.id] == nil, containers[model.id] == nil else { return }
        let id = model.id
        let isVision = model.isVision
        states[id] = .loading(nil)

        loadTasks[id] = Task { [weak self] in
            do {
                let container = try await MlxModelLoader.loadContainer(id: id, isVision: isVision) { fraction in
                    Task { @MainActor in
                        guard let self, case .loading = self.states[id] else { return }
                        self.states[id] = .loading(fraction)
                    }
                }
                guard !Task.isCancelled else { return }
                self?.containers[id] = container
                self?.states[id] = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self?.containers[id] = nil
                self?.states[id] = .failed(MlxModelLoader.describe(error))
            }
            self?.loadTasks[id] = nil
        }
    }

    /// Load one model by Hugging Face id and wrap it as an `MlxChatModel` with that model's
    /// recommended agent sampling. Returns nil if the id isn't in the catalog or the load fails.
    /// Loading is idempotent (`load` no-ops when already resident), so calling this for the same
    /// id across scenarios reuses the warm container. Used by the headless scenario harness to
    /// materialize the planner and each subagent model outside the Ask flow.
    func loadChatModel(_ id: String) async -> MlxChatModel? {
        guard let model = MlxModel.catalog.first(where: { $0.id == id }) else { return nil }
        load(model)
        await loadTasks[id]?.value
        guard let container = containers[id] else { return nil }
        return MlxChatModel(
            container: container, supportsVision: model.isVision,
            modelID: model.id, generateParameters: model.agentParameters
        )
    }

    /// Stop and free `model` (cancels an in-flight load), and clear its chat.
    /// Dropping the container releases the weights; `GPU.clearCache()` then hands
    /// the freed buffers back to the OS so resident memory actually falls.
    func unload(_ model: MlxModel) {
        loadTasks[model.id]?.cancel()
        loadTasks[model.id] = nil
        containers[model.id] = nil
        states[model.id] = .idle
        transcripts[model.id] = nil
        generating.remove(model.id)
        owners[model.id] = nil
        // Freeing a model's weights must NOT delete the user's saved conversations (those are keyed by
        // conversation id in `~/.mispher`, not by model id), so nothing is cleared from the store here.
        MLX.Memory.clearCache()
    }

    // MARK: - Deep agent models (idle residency)

    /// The user's Ask-tab choices for the on-device deep agent: which local models back the planner and
    /// the vision subagent, and how long each may sit idle before it's unloaded (minutes; <= 0 keeps it
    /// resident). Pushed in by ``setDeepAgentConfig(planner:vision:plannerIdleMinutes:visionIdleMinutes:)``
    /// from ``DeepAgentSettings``; default to the bundled DeepAgent models until the user changes them.
    /// Internal (not private) so the idle layer in `MlxModelManager+DeepAgentIdle.swift` can reach them.
    var deepAgentPlannerID = DeepAgentVariant.defaultPlannerID
    var deepAgentVisionID = DeepAgentVariant.defaultVisionID
    var plannerIdleMinutes = DeepAgentVariant.defaultIdleMinutes
    var visionIdleMinutes = DeepAgentVariant.defaultIdleMinutes

    /// Models with a scheduled idle-unload, by id. Cancelled while a model is in active use and rearmed
    /// once it falls idle. Separate from the `.ask`/`.manual` owner system: the deep agent's planner +
    /// vision are time-managed (warm now, freed later) rather than pinned resident while selected.
    var idleTimers: [String: Task<Void, Never>] = [:]
    /// How many in-flight deep-agent turns are using each model. A model is only idle-unloaded when this
    /// hits zero, so a long-running generation is never freed out from under itself.
    var activeUses: [String: Int] = [:]

    public func clearChat(_ model: MlxModel) { clearChat(model.id) }

    /// Clear a chat thread (transcript + saved conversation) by conversation id - deletes its
    /// `~/.mispher` file too. Used to discard a conversation entirely.
    public func clearChat(_ id: String) {
        transcripts[id] = nil
        Task { await conversations.clear(id) }
    }

    /// Drop a conversation's *in-memory* display transcript without deleting its saved file - used when
    /// switching away from a conversation so it's rebuilt fresh from disk on the next resume.
    func unloadTranscript(_ id: String) {
        transcripts[id] = nil
    }

    /// Rebuild a conversation's display transcript from its saved agent history (`~/.mispher`) and
    /// publish it, so the chat surfaces show the prior turns when a stored conversation is reopened.
    /// No-op if the transcript is already live in memory.
    func resume(_ conversationId: String) async {
        guard transcripts[conversationId] == nil else { return }
        let messages = await conversations.messages(conversationId)
        transcripts[conversationId] = Self.reconstructTranscript(messages)
    }

    // MARK: - Conversation lifecycle

    /// Start a fresh Ask conversation pinned to `model` and make it active, returning its id. The id is
    /// assigned synchronously (so the UI can switch to the empty thread immediately); the file is
    /// created and the list refreshed in the background.
    @discardableResult
    func startConversation(model: String) -> String {
        let id = UUID().uuidString
        transcripts[id] = []
        activeConversationId = id
        Task {
            await conversations.create(id: id, model: model, at: Date())
            await refreshConversations()
        }
        return id
    }

    /// Make a saved conversation active, rebuilding its display transcript from disk.
    func activateConversation(_ id: String) {
        activeConversationId = id
        Task {
            await resume(id)
            await refreshConversations()
        }
    }

    /// Refresh the published conversation list from disk (call at launch and after any change).
    func refreshConversations() async {
        conversationList = await conversations.list()
    }

    /// Delete a conversation (its `~/.mispher` file, transcript, and list entry).
    func deleteConversation(_ id: String) {
        if activeConversationId == id { activeConversationId = nil }
        transcripts[id] = nil
        Task {
            await conversations.delete(id)
            await refreshConversations()
        }
    }

    /// Fold a saved `[AgentMessage]` history back into display `ChatMessage`s: each human turn is one
    /// user bubble; the agent turns between two human turns collapse into one model bubble whose
    /// timeline carries the reasoning and tool calls (with their results) - mirroring the live timeline
    /// builder. `<think>` reasoning is preserved (kept in `content`) and split out for display here.
    static func reconstructTranscript(_ messages: [AgentMessage]) -> [ChatMessage] {
        var items: [ChatMessage] = []
        var steps: [AgentStep] = []
        var answer = ""
        var toolStepIndex: [UUID: Int] = [:]
        var hasModelTurn = false

        func flush() {
            guard hasModelTurn else { return }
            items.append(ChatMessage(role: .model, text: answer, timeline: steps))
            steps = []; answer = ""; toolStepIndex = [:]; hasModelTurn = false
        }

        for message in messages {
            // Compaction-synthesized turns: render the summary as a concise system note and drop the
            // synthetic ack, so a resumed compacted conversation doesn't show the summary as a fake
            // user message or the filler ack as a model reply.
            if message.isSummary {
                if message.role == .human {
                    flush()
                    items.append(ChatMessage(role: .model, text: "↻ Earlier conversation summarized."))
                }
                continue
            }
            switch message.role {
            case .system: continue
            case .human:
                flush()
                items.append(ChatMessage(role: .user, text: message.text))
            case .ai:
                hasModelTurn = true
                // Prefer the structured reasoning block; fall back to splitting inline `<think>` for
                // legacy messages or a model that inlines it.
                let thinking: String?
                let answerText: String
                if let blockReasoning = message.reasoning {
                    thinking = blockReasoning
                    answerText = message.text
                } else {
                    let split = ThinkingSplit.split(message.text)
                    thinking = split.thinking
                    answerText = split.answer
                }
                if let thinking, !thinking.isEmpty {
                    steps.append(AgentStep(id: UUID(), kind: .reasoning(thinking)))
                }
                if !answerText.isEmpty { answer += answerText }
                for call in message.toolCalls {
                    toolStepIndex[call.id] = steps.count
                    steps.append(AgentStep(
                        id: UUID(),
                        kind: .tool(name: call.name, input: call.describedArguments, output: nil, done: false)
                    ))
                }
            case .tool:
                hasModelTurn = true
                if let callID = message.toolCallID, let idx = toolStepIndex[callID],
                   case .tool(let name, let input, _, let imageURL, let subagent, _) = steps[idx].kind {
                    steps[idx].kind = .tool(
                        name: name, input: input, output: message.text,
                        imageURL: imageURL, subagent: subagent, done: true
                    )
                }
            }
        }
        flush()
        return items
    }

    /// Stop the in-flight chat turn for `id` (the stop button). Cancellation propagates into the
    /// token loop so generation actually halts; the run unwinds, finishing the reply where it stopped.
    public func cancelChat(_ id: String) {
        chatRunTasks[id]?.cancel()
    }

    // MARK: - Chat (streaming)

    /// Send a chat message to a loaded model (optionally with an image, for VLMs)
    /// and stream the reply into the transcript. Multi-turn: prior turns replay as
    /// history.
    public func send(_ model: MlxModel, prompt: String, imageURL: URL?) async {
        let id = model.id
        guard let container = containers[id], !generating.contains(id) else { return }

        let prior = transcripts[id] ?? []
        transcripts[id, default: []].append(ChatMessage(role: .user, text: prompt))
        transcripts[id, default: []].append(ChatMessage(role: .model, text: ""))
        let replyIndex = (transcripts[id]?.count ?? 1) - 1
        generating.insert(id)
        defer { generating.remove(id) }

        let (events, continuation) = AsyncStream<StreamEvent>.makeStream()
        Task.detached {
            await Self.runStream(
                container: container, history: prior, prompt: prompt, imageURL: imageURL
            ) { continuation.yield($0) }
            continuation.finish()
        }

        var accumulated = ""
        for await event in events {
            switch event {
            case .delta(let chunk):
                accumulated += chunk
                updateReply(id: id, index: replyIndex, text: accumulated, isError: false)
            case .failed(let message):
                updateReply(id: id, index: replyIndex, text: message, isError: true)
            }
        }
    }

    private func updateReply(
        id: String, index: Int, text: String, isError: Bool, timeline: [AgentStep] = [], liveReasoning: String = ""
    ) {
        guard var messages = transcripts[id], messages.indices.contains(index) else { return }
        messages[index].text = text
        messages[index].isError = isError
        messages[index].timeline = timeline
        messages[index].liveReasoning = liveReasoning
        transcripts[id] = messages
    }

    /// Stream a reply off the main actor. Builds a fresh local `ChatSession` (with
    /// replayed history) and emits string deltas. All inputs are `Sendable`.
    private nonisolated static func runStream(
        container: ModelContainer, history: [ChatMessage], prompt: String, imageURL: URL?,
        emit: @Sendable (StreamEvent) -> Void
    ) async {
        do {
            let messages: [Chat.Message] = history.map {
                $0.role == .user ? .user($0.text) : .assistant($0.text)
            }
            let session = ChatSession(container, history: messages)
            let images: [UserInput.Image] = imageURL.map { [.url($0)] } ?? []
            for try await chunk in session.streamResponse(to: prompt, images: images, videos: []) {
                emit(.delta(chunk))
            }
        } catch {
            emit(.failed(MlxModelLoader.describe(error)))
        }
    }

    // MARK: - One-shot ask (main-view spoken prompt)

    /// Stream a single reply from `modelId` for `prompt`, loading the model on
    /// demand. Each delta is delivered synchronously on the main actor via
    /// `onDelta` (no chat history — a fresh one-shot turn). Returns false if the
    /// model couldn't be loaded or the run failed. Backs the main view's
    /// "send my speech to a local model" flow; independent of the chat sidebar.
    func ask(_ prompt: String, modelId: String, onDelta: (String) -> Void) async -> Bool {
        // Bind the Ask flow to this model (loads it; frees the previous one).
        setAskModel(modelId)
        await loadTasks[modelId]?.value
        guard let container = containers[modelId] else { return false }

        let (events, continuation) = AsyncStream<StreamEvent>.makeStream()
        Task.detached {
            await Self.runStream(container: container, history: [], prompt: prompt, imageURL: nil) {
                continuation.yield($0)
            }
            continuation.finish()
        }

        var ok = true
        for await event in events {
            switch event {
            case .delta(let chunk): onDelta(chunk)
            case .failed: ok = false
            }
        }
        return ok
    }

    // MARK: - Ask agent (tool-using, main-view spoken prompt)

    /// Run the on-device ReAct agent for `prompt` on `modelId`, streaming `AgentEvent`s
    /// (answer tokens + tool/plan activity) onto the main actor in order. Loads the
    /// model on demand and reuses the Ask residency. Returns false if the model
    /// couldn't load or the run failed. Backs the main view's spoken-prompt flow.
    public func askAgent(
        _ prompt: String, modelId: String, onEvent: @MainActor (AgentEvent) -> Void
    ) async -> Bool {
        // A new Ask run supersedes an approval a previous (abandoned) Ask run may still be
        // suspended on — reject it so that run unblocks and finishes instead of hanging. Scoped
        // to the Ask surface, so a concurrent HUD-chat run's approval is left alone.
        resolveToolApproval(
            .reject(message: "A new request started before the user answered."),
            scope: Self.askApprovalScope
        )
        guard let agent = await askReactAgent(for: modelId) else { return false }

        // Marshal the agent's events through an ordered stream so per-token UI updates
        // arrive in sequence on the main actor (the run itself is off-actor).
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let runTask = Task.detached {
            let ok = await agent.run([.human(prompt)]) { continuation.yield($0) }
            continuation.finish()
            return ok
        }
        for await event in events { onEvent(event) }
        return await runTask.value
    }

    /// Build the Ask agent for `selection`, loading whatever model(s) it needs and binding the Ask
    /// residency. The DeepAgent sentinel returns ``MispherDeepAgent`` (planner + vision subagent);
    /// any catalog id routes through ``reactAgent(for:chatModel:memory:)``. Returns nil if a needed
    /// model can't load.
    private func askReactAgent(for selection: String) async -> ReactAgent? {
        if let variant = DeepAgentVariant.variant(for: selection) {
            return await deepReactAgent(variant, scope: Self.askApprovalScope)
        }

        // Bind the Ask flow to this model (loads it; frees the previous one).
        setAskModel(selection)
        await loadTasks[selection]?.value
        guard let container = containers[selection],
              let model = MlxModel.catalog.first(where: { $0.id == selection })
        else { return nil }

        let chatModel = MlxChatModel(
            container: container, supportsVision: model.isVision, modelID: model.id,
            contextWindowTokens: model.contextWindowTokens, generateParameters: model.agentParameters
        )
        return reactAgent(for: model, chatModel: chatModel, memory: nil)
    }

    /// Build the on-device deep agent: the user-chosen planner + an optional lazily-loaded vision
    /// subagent, wired via ``MispherDeepAgent``. Returns nil only if the planner isn't in the catalog;
    /// an empty or unknown vision id drops the vision subagent so the planner runs blind. Both models
    /// are ``LazyChatModel``s bound to the idle layer, so the planner loads on its first turn (pre-warmed
    /// on selection) and the VL model loads only when the planner delegates a visual question; each is
    /// freed after its idle timeout. Pass `memory` for a multi-turn surface (the HUD chat) or nil for a
    /// single-turn run. `scope` keys this run's tool approvals (the chat thread id, or ``askApprovalScope``).
    private func deepReactAgent(
        _ variant: DeepAgentVariant, scope: String, memory: (any AgentCheckpointer)? = nil
    ) async -> ReactAgent? {
        let plannerID = deepAgentPlannerID
        let visionID = deepAgentVisionID
        // Make the deep agent the warm Ask selection (pre-warms the planner; the vision stays lazy).
        setAskModel(variant.id)
        guard let plannerCatalog = MlxModel.catalog.first(where: { $0.id == plannerID }) else { return nil }

        let plannerMinutes = plannerIdleMinutes
        let visionMinutes = visionIdleMinutes
        let textChat = LazyChatModel(
            supportsVision: plannerCatalog.isVision, modelID: plannerCatalog.id,
            contextWindowTokens: plannerCatalog.contextWindowTokens,
            begin: { [weak self] in
                guard let self, let model = await beginUse(plannerID) else {
                    throw DeepAgentModelError.unavailable(plannerID)
                }
                return model
            },
            end: { [weak self] in await self?.endUse(plannerID, idleMinutes: plannerMinutes) }
        )
        // Vision is optional: an empty (or stale/unknown) vision id drops the vision subagent so the
        // planner runs blind, rather than failing the whole build (mirrors RippleModelResolution).
        let visionChat: (any ChatModel)? = MlxModel.catalog.first { $0.id == visionID }.map { visionCatalog in
            LazyChatModel(
                supportsVision: visionCatalog.isVision, modelID: visionCatalog.id,
                contextWindowTokens: visionCatalog.contextWindowTokens,
                begin: { [weak self] in
                    guard let self, let model = await beginUse(visionID) else {
                        throw DeepAgentModelError.unavailable(visionID)
                    }
                    return model
                },
                end: { [weak self] in await self?.endUse(visionID, idleMinutes: visionMinutes) }
            )
        }
        let (mcpTools, mcpApprovalDefaults) = await loadMCPTools()
        return MispherDeepAgent.make(
            textModel: textChat, visionModel: visionChat,
            memory: memory,
            approvalHandler: { [weak self] request in
                guard let self else { return .reject(message: nil) }
                return await requestToolApproval(request, scope: scope)
            },
            messageLog: AgentLogSettings.makeLog(),
            policy: agentToolPolicy,
            mcpTools: mcpTools,
            mcpApprovalDefaults: mcpApprovalDefaults
        )
    }

    /// A configured deep-agent model id that isn't in the catalog or fails to load.
    private enum DeepAgentModelError: Error { case unavailable(String) }

    // MARK: - MCP tool loading (deep agent)

    /// Update the MCP servers + tool policy the deep agent uses. Cheap to call on every change;
    /// the live ``MultiServerMCPClient`` is only torn down and rebuilt when the *connectable* server
    /// set actually changes (``loadMCPTools()`` keys it by hash), not once per call.
    public func setAgentToolConfig(mcpServers: [MCPServerConfig], policy: AgentToolPolicy) {
        self.mcpServers = mcpServers
        agentToolPolicy = policy
    }

    /// Connect to the configured MCP servers now - at launch (and on demand) - so their tools are
    /// ready before the first agent run and connection problems surface early instead of stalling
    /// the first query. OAuth servers that aren't signed in yet are skipped (see
    /// ``connectableServers``), so warming never forces a browser open; the user signs in from the
    /// MCP Servers tab. Fire-and-forget: failures are logged and isolated per server.
    public func warmMCP() async {
        mcpWarming = true
        defer { mcpWarming = false }
        _ = await loadMCPTools()
    }

    /// The enabled servers the agent will actually connect to: every enabled server, minus OAuth
    /// servers that have no cached token yet. Excluding the latter keeps warm-up (and the first
    /// agent run) from popping a browser for a server the user hasn't chosen to sign into - they do
    /// that explicitly via the MCP Servers tab's Connect button, which caches the token.
    private var connectableServers: [MCPServerConfig] {
        mcpServers.filter { server in
            guard server.isEnabled else { return false }
            guard server.kind == .http, server.auth == .oauth else { return true }
            return KeychainTokenStorage(serverID: server.id.uuidString).hasToken
        }
    }

    /// Load the deep agent's MCP tools, reusing the persistent client unless the connectable-server
    /// set changed since last time. Returns the tools plus each tool's default approval (its
    /// server's mode). Per-server connection failures are logged and skipped inside `tools()`.
    private func loadMCPTools() async -> (
        tools: [any AgentTool], approvalDefaults: [String: ToolApprovalMode]
    ) {
        let enabled = connectableServers
        guard !enabled.isEmpty else {
            await teardownMCP()
            return ([], [:])
        }

        var hasher = Hasher()
        hasher.combine(enabled)
        let key = hasher.finalize()
        if key != mcpClientKey {
            await mcpClient?.disconnectAll()
            mcpClient = MultiServerMCPClient(configs: enabled)
            mcpClientKey = key
        }

        let tools = await mcpClient?.tools() ?? []
        mcpWarmTools = tools // publish the live tool set for the MCP Servers tab to reflect
        return (tools, mcpApprovalDefaults(servers: enabled, tools: tools))
    }

    /// Disconnect every MCP session and reap any launched stdio subprocess - on config change or
    /// at shutdown. Safe to call when nothing is connected.
    public func teardownMCP() async {
        await mcpClient?.disconnectAll()
        mcpClient = nil
        mcpClientKey = nil
        mcpWarmTools = []
    }

    // MARK: - Tool approvals (human-in-the-loop)

    /// Agent-side entry: publish `request` for `scope`'s approval card and suspend until the
    /// user decides. A stale request in the *same* scope (a superseded run on that surface) is
    /// rejected in favor of this one so no continuation is dropped; other scopes' pending
    /// approvals are left untouched, so a concurrent run keeps its own card.
    func requestToolApproval(
        _ request: ToolApprovalRequest, scope: String
    ) async -> ToolApprovalDecision {
        if let stale = toolApprovalContinuations.removeValue(forKey: scope) {
            stale.resume(returning: .reject(message: "The request was superseded before the user answered."))
        }
        return await withCheckedContinuation { continuation in
            toolApprovalContinuations[scope] = continuation
            pendingToolApprovals[scope] = request
        }
    }

    /// UI-side exit: resolve `scope`'s pending approval with the user's decision and dismiss
    /// its card. No-op when that scope has nothing pending (e.g. a double-click).
    public func resolveToolApproval(_ decision: ToolApprovalDecision, scope: String) {
        guard let continuation = toolApprovalContinuations.removeValue(forKey: scope) else { return }
        pendingToolApprovals[scope] = nil
        continuation.resume(returning: decision)
    }

    /// Pick the agent for `model`: vision models (VLMs) run the screenshot-only
    /// ``VisionAgent``; text models run the general tool-using ``AskAgent``. Pass `memory`
    /// for a multi-turn surface (Settings chat) or nil for a single-turn run (Ask flow).
    /// Shared by ``askAgent(_:modelId:onEvent:)`` and ``sendAgent(_:prompt:imageURL:)`` so
    /// the routing lives in one place.
    private func reactAgent(
        for model: MlxModel, chatModel: MlxChatModel, memory: (any AgentCheckpointer)?
    ) -> ReactAgent {
        let messageLog = AgentLogSettings.makeLog()
        return model.isVision
            ? VisionAgent.make(model: chatModel, memory: memory, messageLog: messageLog)
            : AskAgent.make(model: chatModel, memory: memory, messageLog: messageLog)
    }

    // MARK: - Chat agents (HUD chat, multi-turn with memory)

    /// Like ``send(_:prompt:imageURL:)`` but routes the chat through the on-device
    /// ReAct agent: clipboard + to-do tools and thread-scoped short-term memory (keyed
    /// by model id). Streams the assistant's answer into the model's transcript. Works
    /// for both text LLMs and VLMs (images are forwarded only for vision models).
    public func sendAgent(_ model: MlxModel, prompt: String, imageURL: URL?, threadId: String? = nil) async {
        // The model id locates the loaded weights; the (separate) thread id keys the transcript,
        // in-flight state, approval scope, and saved conversation - so several conversations can run
        // on one model without colliding. Defaults to the model id for legacy single-thread callers.
        let thread = threadId ?? model.id
        guard let container = containers[model.id], !generating.contains(thread) else { return }

        let replyIndex = appendChatTurn(id: thread, prompt: prompt)
        generating.insert(thread)
        defer { generating.remove(thread) }

        let chatModel = MlxChatModel(
            container: container, supportsVision: model.isVision, modelID: model.id,
            contextWindowTokens: model.contextWindowTokens, generateParameters: model.agentParameters
        )
        let agent = reactAgent(for: model, chatModel: chatModel, memory: conversations)
        let human: AgentMessage = .human(prompt, imageURLs: imageURL.map { [$0] } ?? [])
        await runChatAgent(agent, id: thread, replyIndex: replyIndex, human: human)
    }

    /// Run a DeepAgent variant as the HUD chat turn: the planner + vision subagent with the
    /// same thread-scoped memory as a catalog-model chat, keyed by the variant's sentinel id.
    /// The deep agent brings the real-disk filesystem gated behind ``requestToolApproval(_:scope:)``,
    /// so the chat renders the same approval card as the Ask flow while a call waits. No
    /// image parameter: the planner is blind and captures screenshots itself.
    public func sendDeepAgent(_ variant: DeepAgentVariant, prompt: String, threadId: String? = nil) async {
        // Defaults to the variant sentinel for legacy single-thread callers; a conversation passes its
        // own id so several deep-agent conversations stay distinct (see ``sendAgent``).
        let thread = threadId ?? variant.id
        guard !generating.contains(thread) else { return }

        let replyIndex = appendChatTurn(id: thread, prompt: prompt)
        generating.insert(thread)
        defer { generating.remove(thread) }

        // A new run on this thread supersedes an approval an abandoned earlier run on the same
        // thread may still be suspended on — reject it so that run unblocks and finishes
        // (mirrors askAgent). Scoped to this thread id, so other threads' runs are untouched.
        resolveToolApproval(
            .reject(message: "A new request started before the user answered."), scope: thread
        )

        guard let agent = await deepReactAgent(variant, scope: thread, memory: conversations) else {
            updateReply(
                id: thread, index: replyIndex,
                text: "Couldn't load the \(variant.label) models.", isError: true
            )
            return
        }
        await runChatAgent(agent, id: thread, replyIndex: replyIndex, human: .human(prompt))
    }

    /// Append a user turn plus an empty model reply to `id`'s transcript, returning the
    /// reply's index for streaming updates.
    private func appendChatTurn(id: String, prompt: String) -> Int {
        transcripts[id, default: []].append(ChatMessage(role: .user, text: prompt))
        transcripts[id, default: []].append(ChatMessage(role: .model, text: ""))
        return (transcripts[id]?.count ?? 1) - 1
    }

    /// Run one agent chat turn and fold its event stream into the reply at `replyIndex`:
    /// the ordered reasoning/tool/todo timeline plus the live streaming text and the final
    /// answer, all surfaced in the chat bubble.
    private func runChatAgent(
        _ agent: ReactAgent, id: String, replyIndex: Int, human: AgentMessage
    ) async {
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let runTask = Task.detached {
            await agent.run([human], threadId: id) { continuation.yield($0) }
            continuation.finish()
        }
        chatRunTasks[id] = runTask
        defer { chatRunTasks[id] = nil }

        var builder = AgentTimelineBuilder()
        for await event in events {
            if case .failed(let message) = event, builder.answer.isEmpty, builder.steps.isEmpty {
                updateReply(id: id, index: replyIndex, text: message, isError: true)
                continue
            }
            builder.consume(event)
            let text = builder.answer.isEmpty ? builder.streamingText : builder.answer
            updateReply(
                id: id, index: replyIndex, text: text, isError: false,
                timeline: builder.steps, liveReasoning: builder.streamingReasoning
            )
        }
        await runTask.value
    }

    // MARK: - Compaction (manual /compact equivalent)

    /// Summarize a conversation's older turns now, freeing its context window - the manual companion
    /// to the automatic 85% trigger. Builds a memory-backed agent for the thread's pinned model, runs
    /// ``ReactAgent/compact(threadId:)`` (which rewrites the stored history to `[summary] + tail` and
    /// offloads the originals to `~/.mispher/<id>/history/`), then appends a note to the live
    /// transcript. The visible scrollback is kept; the next turn reloads the compacted history.
    public func compactConversation(_ threadId: String) async {
        guard !generating.contains(threadId), !isSummarizing.contains(threadId) else { return }
        // The pinned model from the saved conversation; fall back to the thread id itself, which is the
        // model / variant id for the HUD chat's model-keyed threads.
        let model = await conversations.meta(threadId)?.model ?? threadId
        isSummarizing.insert(threadId)
        defer { isSummarizing.remove(threadId) }

        let agent: ReactAgent?
        if let variant = DeepAgentVariant.variant(for: model) {
            agent = await deepReactAgent(variant, scope: threadId, memory: conversations)
        } else {
            setAskModel(model)
            await loadTasks[model]?.value
            if let container = containers[model],
               let catalog = MlxModel.catalog.first(where: { $0.id == model }) {
                let chatModel = MlxChatModel(
                    container: container, supportsVision: catalog.isVision, modelID: catalog.id,
                    contextWindowTokens: catalog.contextWindowTokens,
                    generateParameters: catalog.agentParameters
                )
                agent = reactAgent(for: catalog, chatModel: chatModel, memory: conversations)
            } else {
                agent = nil
            }
        }
        guard let agent, let outcome = await agent.compact(threadId: threadId) else { return }

        // Keep the on-screen scrollback; append a note confirming the compaction (UI-only - the
        // store already holds [summary] + tail, and resuming rebuilds from it).
        let note = "↻ Context compacted: \(Self.tokensLabel(outcome.tokensBefore)) → "
            + "\(Self.tokensLabel(outcome.tokensAfter)) tokens. Older turns summarized; originals saved."
        transcripts[threadId, default: []].append(ChatMessage(role: .model, text: note))
    }

    /// A compact token count for a note, e.g. `31.2k` or `840`.
    private static func tokensLabel(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    // MARK: - Translation

    /// Translate `text` into `targetLanguage` using the (loaded-on-demand) instruct model
    /// `modelId`. `prompt` is the user-editable instruction block (Settings ▸ Translate); the
    /// target language is substituted into it. Returns nil on failure. Used by the Translate pass.
    public func translate(_ text: String, prompt: String, modelId: String, targetLanguage: String) async -> String? {
        // Run-scoped claim so the model loads on demand and frees afterwards unless the warmed
        // translation toggle (the `.translation` owner) is also keeping it resident.
        retain(modelId, by: .translationRun)
        defer { release(modelId, by: .translationRun) }
        await loadTasks[modelId]?.value
        guard let container = containers[modelId],
              let model = MlxModel.catalog.first(where: { $0.id == modelId })
        else { return nil }

        // Translation is a pure transform: drive it through a no-tool ReAct agent (single
        // model round) and read the final answer off the event stream. `supportsVision` is
        // false — the Translate pass always runs on a text instruct model.
        let chatModel = MlxChatModel(
            container: container, supportsVision: false, modelID: model.id,
            generateParameters: model.agentParameters
        )
        let agent = TranslationAgent.make(
            model: chatModel, instructions: prompt, targetLanguage: targetLanguage, text: text,
            messageLog: AgentLogSettings.makeLog()
        )

        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let runTask = Task.detached {
            let ok = await agent.run([.human(text)]) { continuation.yield($0) }
            continuation.finish()
            return ok
        }
        var builder = AgentTimelineBuilder()
        for await event in events { builder.consume(event) }
        let ok = await runTask.value
        let answer = builder.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return ok && !answer.isEmpty ? answer : nil
    }

    // MARK: - Dictation cleanup

    /// Clean up a raw transcript with the (loaded-on-demand) instruct model `modelId`:
    /// punctuation, capitalization, filler/number/abbreviation fixes, dictation commands.
    /// Returns nil on failure (e.g. the model isn't downloaded) so the caller can fall back
    /// to the un-cleaned text. Mirrors ``translate(_:modelId:targetLanguage:)``. `prompt` is the
    /// user-editable instruction block (Settings ▸ Dictation); the transcript is baked into it.
    public func cleanup(_ text: String, prompt: String, modelId: String) async -> String? {
        // Distinct in-flight owner so disabling AI cleanup mid-run (which releases the warmed
        // `.cleanup` owner) can't unload the model before this run finishes.
        retain(modelId, by: .cleanupRun)
        defer { release(modelId, by: .cleanupRun) }
        await loadTasks[modelId]?.value
        guard let container = containers[modelId],
              let model = MlxModel.catalog.first(where: { $0.id == modelId })
        else { return nil }

        // Cleanup is a pure text transform: drive it through a no-tool ReAct agent (single
        // model round) and read the final answer off the event stream. Always a text model.
        let chatModel = MlxChatModel(
            container: container, supportsVision: false, modelID: model.id,
            generateParameters: model.agentParameters
        )
        let agent = CleanupAgent.make(
            model: chatModel, instructions: prompt, text: text, messageLog: AgentLogSettings.makeLog()
        )

        // The transcript lives in the system prompt; drive the run with a fixed neutral user turn so
        // a dictated question is cleaned, not answered.
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let runTask = Task.detached {
            let ok = await agent.run([.human(CleanupPrompt.userDirective)]) { continuation.yield($0) }
            continuation.finish()
            return ok
        }
        var builder = AgentTimelineBuilder()
        for await event in events { builder.consume(event) }
        let ok = await runTask.value
        let answer = builder.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return ok && !answer.isEmpty ? answer : nil
    }

    // MARK: - Rewrite (edit selected text by voice)

    /// Apply a spoken `instruction` to `selection` with the (loaded-on-demand) instruct model
    /// `modelId`, returning the rewritten text (nil on failure, e.g. the model isn't
    /// downloaded). Mirrors ``cleanup(_:modelId:)`` — the selection is baked into the system
    /// prompt and the instruction is the human turn. `prompt` is the user-editable instruction
    /// block (Settings ▸ Rewrite); the selected text is appended to it automatically.
    public func rewrite(selection: String, instruction: String, prompt: String, modelId: String) async -> String? {
        // Loaded on demand and freed afterwards — reference-counted, so it stays resident only
        // if another feature (cleanup/translation/ask) also uses the same model.
        retain(modelId, by: .rewrite)
        defer { release(modelId, by: .rewrite) }
        await loadTasks[modelId]?.value
        guard let container = containers[modelId],
              let model = MlxModel.catalog.first(where: { $0.id == modelId })
        else { return nil }

        let chatModel = MlxChatModel(
            container: container, supportsVision: false, modelID: model.id,
            generateParameters: model.agentParameters
        )
        let agent = RewriteAgent.make(
            model: chatModel, selection: selection, instructions: prompt, messageLog: AgentLogSettings.makeLog()
        )

        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let runTask = Task.detached {
            let ok = await agent.run([.human(instruction)]) { continuation.yield($0) }
            continuation.finish()
            return ok
        }
        var builder = AgentTimelineBuilder()
        for await event in events { builder.consume(event) }
        let ok = await runTask.value
        let answer = builder.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return ok && !answer.isEmpty ? answer : nil
    }

    /// Whether the translation model is loaded and ready.
    func isReady(modelId: String) -> Bool {
        if case .ready = states[modelId] ?? .idle { return true }
        return false
    }

    // MARK: - Disk downloads (manage files without loading into memory)

    public func diskState(for model: MlxModel) -> DiskState { diskStates[model.id] ?? .unknown }

    /// Refresh on-disk presence for every catalog model. Call when the Local-models settings
    /// appear — cheap (a filesystem stat per model). Leaves in-flight downloads alone.
    public func refreshDiskStates() {
        for model in MlxModel.catalog {
            if diskStates[model.id]?.isDownloading == true { continue }
            diskStates[model.id] = MlxModelLoader.isDownloadedOnDisk(model.id) ? .downloaded : .notDownloaded
        }
    }

    /// Download a model's files to the HF cache without loading it into memory. It then loads
    /// fast (no re-download) the first time it's chatted with.
    public func downloadToDisk(_ model: MlxModel) {
        let id = model.id
        guard downloadTasks[id] == nil, diskStates[id]?.isDownloading != true else { return }
        diskStates[id] = .downloading(nil)
        // swift-huggingface streams each file to a URLSession temp (CFNetworkDownload_*.tmp in
        // the process temp dir) before moving it into the cache, and its Xet transport reports
        // no incremental progress — so neither the library callback nor polling the cache dir
        // moves the bar. Poll the size of the in-flight temp files instead for a real fraction.
        let expectedBytes = Int64(model.approxGB * 1_000_000_000)
        let startedAt = Date()
        let pollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard expectedBytes > 0 else { continue }
                let fraction = min(0.99, Double(Self.inFlightDownloadBytes(since: startedAt)) / Double(expectedBytes))
                await MainActor.run {
                    guard let self, self.diskStates[id]?.isDownloading == true else { return }
                    // Below a hair of progress, keep the indeterminate spinner so the row never
                    // looks pinned at 0% before the first bytes land.
                    self.diskStates[id] = fraction > 0.001 ? .downloading(fraction) : .downloading(nil)
                }
            }
        }
        downloadTasks[id] = Task { [weak self] in
            defer { pollTask.cancel() }
            do {
                try await MlxModelLoader.downloadSnapshot(id: id) { _ in }
                self?.diskStates[id] = .downloaded
            } catch {
                self?.diskStates[id] = .failed(MlxModelLoader.describe(error))
            }
            self?.downloadTasks[id] = nil
        }
    }

    /// Total bytes of the URLSession download temp files that have been written since `startedAt`
    /// — the live in-flight bytes of an active download (each file streams to a
    /// `CFNetworkDownload_*.tmp` in the process temp dir before being moved into the HF cache).
    /// The modification-date filter skips stale leftovers from earlier downloads. No network.
    private nonisolated static func inFlightDownloadBytes(since startedAt: Date) -> Int64 {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: Array(keys)
        ) else { return 0 }
        var total: Int64 = 0
        for url in files where url.lastPathComponent.hasPrefix("CFNetworkDownload") {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let modified = values.contentModificationDate, modified >= startedAt
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Delete a model's local files (and free it from memory if it happens to be loaded).
    public func deleteFromDisk(_ model: MlxModel) {
        let id = model.id
        downloadTasks[id]?.cancel()
        downloadTasks[id] = nil
        unload(model) // free memory + drop owners if resident; safe no-op otherwise
        MlxModelLoader.removeFromDisk(id)
        diskStates[id] = .notDownloaded
    }
}
