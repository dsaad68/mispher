import Foundation

/// How a tool's calls are gated, chosen by the user per tool (or per MCP server). The
/// user-facing projection of the human-in-the-loop machinery: where ``InterruptOnConfig`` says
/// only *whether* a tool is intercepted, this names the three policies a person actually picks.
///
/// - ``approve``: run every call immediately, no prompt (the agent's default for safe tools).
/// - ``ask``: intercept every call and wait for the user's decision in the approval card.
/// - ``deny``: intercept every call and auto-reject it without prompting; the model still sees
///   the tool but can never run it (distinct from deactivating, which hides the tool entirely).
public enum ToolApprovalMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case approve
    case ask
    case deny

    public var id: String { rawValue }

    /// A short label for the picker in Settings.
    public var label: String {
        switch self {
        case .approve: return "Approve"
        case .ask: return "Ask"
        case .deny: return "Deny"
        }
    }
}
