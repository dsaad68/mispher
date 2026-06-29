import Foundation

/// Short-term memory for an agent — Mispher's port of LangChain/LangGraph's
/// checkpointer. It persists a thread's conversation (`messages`) keyed by `threadId`
/// so multi-turn chats remember prior turns. Conform with a disk- or DB-backed store
/// for durable memory.
public protocol AgentCheckpointer: Sendable {
    func load(_ threadId: String) async -> [AgentMessage]
    func save(_ threadId: String, _ messages: [AgentMessage]) async
}

/// In-memory checkpointer — the `InMemorySaver` equivalent. Thread histories live for
/// the process lifetime.
public actor InMemoryCheckpointer: AgentCheckpointer {
    private var threads: [String: [AgentMessage]] = [:]

    public init() {}

    public func load(_ threadId: String) -> [AgentMessage] {
        threads[threadId] ?? []
    }

    public func save(_ threadId: String, _ messages: [AgentMessage]) {
        threads[threadId] = messages
    }

    /// Forget a thread's history (used when the user clears a chat).
    public func clear(_ threadId: String) {
        threads[threadId] = nil
    }
}
