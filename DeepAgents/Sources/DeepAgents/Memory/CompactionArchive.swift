import Foundation

/// A sink for the original messages a compaction evicts — deepagents' filesystem-preservation
/// step. Before ``SummarizationMiddleware`` replaces the older block with a summary, it hands the
/// evicted originals here so they stay recoverable; the returned reference (typically a file path)
/// is embedded in the summary turn so the agent can point back to the full transcript.
///
/// The framework stays path-agnostic: each host's checkpointer implements this against its own
/// layout (Ripple writes `~/.ripple/sessions/<id>/history/part-{n}.jsonl`; the Mispher app writes
/// `~/.mispher/<id>/history/part-{n}.jsonl`). Conforming the same store that is the agent's
/// ``AgentCheckpointer`` lets ``createDeepAgent`` wire the archive in automatically.
public protocol CompactionArchive: Sendable {
    /// Persist one compaction's evicted messages as the next history part for `threadId`.
    /// - Returns: a human-readable reference to the stored part (a path), or `nil` if it could
    ///   not be written. A `nil` return just omits the "saved to …" pointer from the summary.
    func archive(_ messages: [AgentMessage], threadId: String) async -> String?
}
