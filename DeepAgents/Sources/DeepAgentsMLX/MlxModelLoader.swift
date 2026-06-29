import DeepAgents
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// The shared, app-agnostic model-loading core: turn a Hugging Face model id into a running MLX
/// container (with the LFM2.5 chat-template / projector repairs) and the HF-cache helpers that back
/// download / delete. The terminal harness loads models through an instance of this directly; the
/// app's `MlxModelManager` builds its residency, transcript, and approval orchestration on top of
/// these statics. Kept in the core so the shared base harness can load models without the app.
@MainActor
public final class MlxModelLoader {
    public init() {}

    private var containers: [String: ModelContainer] = [:]

    /// Load one model by Hugging Face id and wrap it as an `MlxChatModel` with that model's
    /// recommended agent sampling. Returns nil if the id isn't in the catalog or the load fails.
    /// The container is cached, so loading the same id again reuses the warm copy - used by the
    /// headless scenario harness and the chat REPL to materialize the planner and each subagent.
    public func loadChatModel(_ id: String) async -> MlxChatModel? {
        await loadChatModel(id, progress: { _ in })
    }

    /// As above, but reports load progress (0...1) so a caller can draw a progress bar. A warm
    /// (cached) container reports 1 immediately; a cold one threads the container loader's
    /// download / verify fraction through.
    public func loadChatModel(
        _ id: String, progress: @escaping @Sendable (Double) -> Void
    ) async -> MlxChatModel? {
        guard let model = MlxModel.catalog.first(where: { $0.id == id }) else { return nil }
        let container: ModelContainer
        if let cached = containers[id] {
            container = cached
            progress(1)
        } else {
            guard let loaded = try? await Self.loadContainer(id: id, isVision: model.isVision, progress: progress)
            else { return nil }
            containers[id] = loaded
            container = loaded
        }
        return MlxChatModel(
            container: container, supportsVision: model.isVision,
            modelID: model.id, contextWindowTokens: model.contextWindowTokens,
            generateParameters: model.agentParameters
        )
    }

    // MARK: - Idle residency

    /// Models with a scheduled idle-unload, by id. Cancelled while a model is in active use and
    /// rearmed once it falls idle.
    private var idleTimers: [String: Task<Void, Never>] = [:]
    /// How many in-flight turns are currently using each model. A model is only idle-unloaded when this
    /// hits zero, so a long-running generation is never freed out from under itself.
    private var activeUses: [String: Int] = [:]

    /// Resolve `id` for an in-flight turn: load it if needed (caching the container), cancel any pending
    /// idle unload, and mark it in active use. Returns nil if the model can't load. Pair every call with
    /// ``endUse(_:idleMinutes:)`` so the idle timer is rearmed when the turn finishes.
    public func beginUse(_ id: String) async -> MlxChatModel? {
        idleTimers[id]?.cancel()
        idleTimers[id] = nil
        activeUses[id, default: 0] += 1
        guard let model = await loadChatModel(id) else {
            // Loading failed: undo the active-use claim so a later turn can still idle-unload.
            endActiveUse(id)
            return nil
        }
        return model
    }

    /// Release one in-flight turn's claim on `id`. When the last one finishes, (re)arm the idle timer -
    /// after `idleMinutes` of no use the cached container is dropped and its weights freed.
    /// `idleMinutes <= 0` keeps the model resident (no timer is scheduled).
    public func endUse(_ id: String, idleMinutes: Int) {
        endActiveUse(id)
        guard activeUses[id, default: 0] == 0, idleMinutes > 0 else { return }
        let seconds = Double(idleMinutes) * 60
        idleTimers[id]?.cancel()
        idleTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.idleUnload(id)
        }
    }

    private func endActiveUse(_ id: String) {
        if let count = activeUses[id] { activeUses[id] = max(0, count - 1) }
    }

    /// Drop `id`'s container if it's still idle (no active use crept in while the timer ran).
    private func idleUnload(_ id: String) {
        idleTimers[id] = nil
        guard activeUses[id, default: 0] == 0 else { return }
        unload(id)
    }

    /// Drop `id`'s cached container and hand the freed buffers back to the OS. Dropping the only strong
    /// reference frees the weights; `MLX.Memory.clearCache()` then returns the buffers so resident
    /// memory actually falls. The next ``beginUse(_:)`` reloads it.
    public func unload(_ id: String) {
        idleTimers[id]?.cancel()
        idleTimers[id] = nil
        containers[id] = nil
        MLX.Memory.clearCache()
    }

    // MARK: - Container loading

    public nonisolated static func loadContainer(
        id: String, isVision: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        let factory: any ModelFactory = isVision ? VLMModelFactory.shared : LLMModelFactory.shared
        let configuration = ModelConfiguration(id: id)
        let handler: @Sendable (Progress) -> Void = { progress($0.fractionCompleted) }
        // Repair a stale chat template before the tokenizer reads it (some LFM2.5
        // conversions ship one that can't render tool calls - see below).
        patchLFM2ChatTemplate(repoId: id)
        do {
            return try await factory.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: configuration, progressHandler: handler
            )
        } catch {
            guard describe(error).contains("multi_modal_projector.layer_norm"),
                  patchProjectorUseLayernorm(repoId: id)
            else { throw error }
            return try await factory.loadContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                configuration: configuration, progressHandler: handler
            )
        }
    }

    /// Set `projector_use_layernorm: true` in the cached `config.json` for `repoId`
    /// (the weight error happens after download, so the file is already present).
    /// Returns whether anything was changed. Writes through the cache symlink.
    private nonisolated static func patchProjectorUseLayernorm(repoId: String) -> Bool {
        let fm = FileManager.default
        let snapshots = hubRepoDirectory(repoId).appendingPathComponent("snapshots")
        guard let hashes = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
        else { return false }

        var patched = false
        for hashDir in hashes {
            let configURL = hashDir.appendingPathComponent("config.json")
            guard fm.fileExists(atPath: configURL.path),
                  let data = try? Data(contentsOf: configURL),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["projector_use_layernorm"] as? Bool) == false
            else { continue }
            json["projector_use_layernorm"] = true
            if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
               (try? out.write(to: configURL, options: [])) != nil {
                patched = true
            }
        }
        return patched
    }

    /// Rewrite a stale LFM2.5 chat template in the cache to the canonical one
    /// (`LFM2ChatTemplate.canonical`) so tool use works. Some community MLX conversions of
    /// LFM2.5 - e.g. `mlx-community/LFM2.5-VL-1.6B-8bit` - ship a `chat_template.jinja` that
    /// has no `render_tool_calls` macro: it injects the tool list into the system prompt but
    /// silently drops an assistant turn's `tool_calls` when re-rendering history, so once the
    /// model makes its first tool call that call vanishes from the next round's prompt and the
    /// ReAct loop's tool use collapses (the larger 1.6B model "stops calling tools"). It also
    /// omits LFM2.5's trained `Today's date: …` framing. swift-transformers' tokenizer loader
    /// reads `chat_template.jinja` and merges it over `tokenizer_config.json`, so we write the
    /// canonical template to both. Only LFM2 repos whose cached template lacks tool-call
    /// rendering are touched - a correct template is left as-is, so this self-heals upstream.
    private nonisolated static func patchLFM2ChatTemplate(repoId: String) {
        guard repoId.lowercased().contains("lfm2") else { return }
        let fm = FileManager.default
        let snapshots = hubRepoDirectory(repoId).appendingPathComponent("snapshots")
        guard let hashes = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
        else { return }

        for hashDir in hashes {
            let configURL = hashDir.appendingPathComponent("tokenizer_config.json")
            // Only the snapshot that holds the tokenizer config is one we load from.
            guard fm.fileExists(atPath: configURL.path) else { continue }

            let jinjaURL = hashDir.appendingPathComponent("chat_template.jinja")
            let jinjaTemplate = try? String(contentsOf: jinjaURL, encoding: .utf8)
            let configJSON = (try? Data(contentsOf: configURL)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let configTemplate = configJSON?["chat_template"] as? String

            // The loader prefers the standalone `.jinja`; fall back to the config's key.
            let effective = jinjaTemplate ?? configTemplate
            if LFM2ChatTemplate.rendersToolCalls(effective) { continue } // already good

            // Authoritative for the loader: the standalone `.jinja` file.
            try? Data(LFM2ChatTemplate.canonical.utf8).write(to: jinjaURL, options: [])
            // Mirror into the config for any loader that reads only `tokenizer_config.json`.
            if var json = configJSON {
                json["chat_template"] = LFM2ChatTemplate.canonical
                if let out = try? JSONSerialization.data(
                    withJSONObject: json, options: [.prettyPrinted]
                ) {
                    try? out.write(to: configURL, options: [])
                }
            }
        }
    }

    public nonisolated static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - HF cache helpers

    /// The Hugging Face hub cache root (`$HF_HOME/hub`, else `~/.cache/huggingface/hub`).
    /// The app isn't sandboxed, so this is where `#hubDownloader()` reads/writes.
    private nonisolated static func hubBase() -> URL {
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"] {
            return URL(fileURLWithPath: hfHome).appendingPathComponent("hub")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    /// The cache directory for `repoId` (`…/hub/models--org--repo`).
    private nonisolated static func hubRepoDirectory(_ repoId: String) -> URL {
        hubBase().appendingPathComponent("models--" + repoId.replacingOccurrences(of: "/", with: "--"))
    }

    /// Whether `repoId`'s weights are present in the cache (any snapshot holds a
    /// `.safetensors` file). A pure filesystem check - no network.
    public nonisolated static func isDownloadedOnDisk(_ repoId: String) -> Bool {
        let fm = FileManager.default
        let snapshots = hubRepoDirectory(repoId).appendingPathComponent("snapshots")
        guard let hashes = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
        else { return false }
        for hash in hashes {
            if let files = try? fm.contentsOfDirectory(at: hash, includingPropertiesForKeys: nil),
               files.contains(where: { $0.pathExtension == "safetensors" }) {
                return true
            }
        }
        return false
    }

    /// Remove `repoId`'s local files from the cache.
    public nonisolated static func removeFromDisk(_ repoId: String) {
        try? FileManager.default.removeItem(at: hubRepoDirectory(repoId))
    }

    /// Download `id`'s model + tokenizer files to the cache without instantiating it. Reuses
    /// the same `#hubDownloader()` the loader uses; `useLatest: false` returns the cached copy
    /// if already complete.
    public nonisolated static func downloadSnapshot(
        id: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let handler: @Sendable (Progress) -> Void = { progress($0.fractionCompleted) }
        _ = try await #hubDownloader().download(
            id: id, revision: nil,
            matching: ["*.safetensors", "*.json", "*.jinja"],
            useLatest: false, progressHandler: handler
        )
    }
}
