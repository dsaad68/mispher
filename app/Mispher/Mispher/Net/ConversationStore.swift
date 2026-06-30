import DeepAgents
import Foundation

/// One saved Ask conversation's metadata - the header (first) line of its `~/.mispher/<id>.jsonl` file.
struct ConversationMeta: Codable, Identifiable, Sendable, Equatable {
    let id: String
    /// The Ask model (catalog id or DeepAgent sentinel) the conversation runs on, so resuming it can
    /// reselect the same model.
    var model: String
    /// First user line, shown as the conversation's label in the list.
    var title: String
    let createdAt: Date
    var updatedAt: Date
}

/// Persists Ask conversations to `~/.mispher`, one JSONL file per conversation: a metadata header line
/// followed by the agent's `[AgentMessage]` history (which keeps `<think>` reasoning verbatim in
/// `content`). This is the user's *reusable* conversation history - distinct from the opt-in developer
/// message log (``JSONLMessageLog``), which records every run (transcription/translation/fixes) for
/// debugging and can't be read back.
///
/// It doubles as the agent's ``AgentCheckpointer``: the same file that lists and shows a conversation
/// also restores the agent's context on resume, so a reopened thread isn't amnesiac. Keyed by a stable
/// conversation id (a UUID), independent of which model the conversation runs on - so two conversations
/// can share a model without colliding.
actor ConversationStore: AgentCheckpointer {
    /// Folder under the user's home where conversations live.
    static let folderName = ".mispher"

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Cached header metadata per conversation, so listing doesn't re-read every file. Populated lazily
    /// on first access (kept off the app-launch path).
    private var metas: [String: ConversationMeta] = [:]
    /// Conversations created but not yet saved a turn - kept out of the list and off disk so a
    /// started-but-never-used conversation doesn't clutter history or persist across launches.
    private var unsaved: Set<String> = []
    private var didLoadIndex = false

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Self.folderName, isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Index

    /// Scan the folder once, reading each file's header line into the cache.
    private func ensureIndex() {
        guard !didLoadIndex else { return }
        didLoadIndex = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "jsonl" {
            if let meta = readMeta(file) { metas[meta.id] = meta }
        }
    }

    private func fileURL(_ id: String) -> URL {
        // Conversation ids are UUIDs, but sanitize defensively so any key (e.g. a model id with `/`)
        // can't escape the folder or create stray subdirectories.
        let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return directory.appendingPathComponent("\(safe).jsonl", isDirectory: false)
    }

    /// Decode just the header line of a conversation file (cheap - avoids loading the whole transcript).
    private func readMeta(_ file: URL) -> ConversationMeta? {
        guard let data = try? Data(contentsOf: file),
              let firstLine = data.split(separator: 0x0A, maxSplits: 1).first
        else { return nil }
        return try? decoder.decode(ConversationMeta.self, from: Data(firstLine))
    }

    // MARK: - Listing / lifecycle

    /// All conversations that have had at least one turn, most-recently-active first.
    func list() -> [ConversationMeta] {
        ensureIndex()
        return metas.values.filter { !unsaved.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func meta(_ id: String) -> ConversationMeta? {
        ensureIndex()
        return metas[id]
    }

    /// Create a fresh, empty conversation with id `id`, pinned to `model`, returning its metadata. The
    /// id is supplied by the caller so the UI can switch to it synchronously before this lands.
    @discardableResult
    func create(id: String, model: String, at now: Date) -> ConversationMeta {
        ensureIndex()
        let meta = ConversationMeta(
            id: id, model: model, title: "New conversation", createdAt: now, updatedAt: now
        )
        metas[meta.id] = meta
        // Hold the file (and list entry) back until the first turn is saved.
        unsaved.insert(meta.id)
        return meta
    }

    func delete(_ id: String) {
        ensureIndex()
        metas[id] = nil
        unsaved.remove(id)
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    // MARK: - AgentCheckpointer

    func load(_ threadId: String) -> [AgentMessage] {
        readMessages(threadId)
    }

    func save(_ threadId: String, _ messages: [AgentMessage]) {
        ensureIndex()
        unsaved.remove(threadId) // first turn lands - the conversation now lists and persists
        // Preserve the creation time + pinned model; refresh the title from the first human turn and
        // bump the activity stamp. (A turn on an unknown thread is created on the fly so nothing is lost.)
        let existing = metas[threadId]
        let now = Date()
        let meta = ConversationMeta(
            id: threadId,
            model: existing?.model ?? "",
            title: Self.title(from: messages) ?? existing?.title ?? "New conversation",
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        metas[threadId] = meta
        write(meta: meta, messages: messages)
    }

    func clear(_ threadId: String) {
        delete(threadId)
    }

    // MARK: - Messages

    /// The raw agent history for a conversation (used to rebuild the display transcript on resume).
    func messages(_ id: String) -> [AgentMessage] { readMessages(id) }

    private func readMessages(_ id: String) -> [AgentMessage] {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return [] }
        // Line 0 is the metadata header; the rest are messages.
        return data.split(separator: 0x0A).dropFirst()
            .compactMap { try? decoder.decode(AgentMessage.self, from: Data($0)) }
    }

    private func write(meta: ConversationMeta, messages: [AgentMessage]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data()
        if let header = try? encoder.encode(meta) {
            data.append(header)
            data.append(0x0A)
        }
        for message in messages {
            guard let line = try? encoder.encode(message) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: fileURL(meta.id), options: .atomic)
    }

    /// First non-empty human line, trimmed, as the conversation's label. Compaction-synthesized
    /// summary turns are `.human` too, so they're skipped - otherwise the first save after a
    /// compaction would relabel the conversation with the summary boilerplate.
    private static func title(from messages: [AgentMessage]) -> String? {
        guard let text = messages.first(where: { $0.role == .human && !$0.isSummary })?.text else { return nil }
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }
}

extension ConversationStore: CompactionArchive {
    /// Offload one compaction's evicted originals to `~/.mispher/<id>/history/part-{n}.jsonl` (a
    /// sibling folder beside the flat `<id>.jsonl`), so the full pre-compaction transcript stays
    /// recoverable even though the live conversation file now holds only `[summary] + tail`.
    func archive(_ messages: [AgentMessage], threadId: String) -> String? {
        let safe = threadId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        let dir = directory.appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        let fileURL = dir.appendingPathComponent("part-\(Self.nextPartNumber(in: dir)).jsonl")
        var data = Data()
        for message in messages {
            guard let line = try? encoder.encode(message) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return fileURL.path
    }

    /// One past the highest `part-{n}.jsonl` already in `dir` (1 for an empty/new history folder).
    private static func nextPartNumber(in dir: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return 1 }
        let numbers = files.compactMap { url -> Int? in
            let name = url.lastPathComponent
            guard name.hasPrefix("part-"), name.hasSuffix(".jsonl") else { return nil }
            return Int(name.dropFirst("part-".count).dropLast(".jsonl".count))
        }
        return (numbers.max() ?? 0) + 1
    }
}
