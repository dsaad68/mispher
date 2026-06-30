import DeepAgents
import SwiftUI

/// The human-in-the-loop approval card. It appears when the agent asks to run a gated
/// tool (reading or writing a real file on the user's Mac) — the run is suspended inside
/// `HumanInTheLoopMiddleware` until the user decides. Approve lets the call run as
/// issued; Deny feeds a rejection back so the model adjusts and continues without it.
struct ToolApprovalCard: View {
    let request: ToolApprovalRequest
    let approve: () -> Void
    let deny: () -> Void

    /// What the agent is asking for, in plain words (the file tools get bespoke phrasing).
    private var intent: String {
        switch request.toolName {
        case "read_file": return "The agent wants to read this file:"
        case "write_file": return "The agent wants to write this file:"
        case "edit_file": return "The agent wants to edit this file:"
        case "ls": return "The agent wants to list this folder:"
        default: return "The agent wants to run `\(request.toolName)` with:"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.warm)
                Text("Approval needed · \(TranscriptionViewModel.friendlyToolName(request.toolName))")
                    .font(.sans(11.5, weight: .semibold))
                    .foregroundStyle(Palette.fg)
                Spacer(minLength: 0)
            }

            Text(intent)
                .font(.sans(11))
                .foregroundStyle(Palette.fg2)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(request.argumentRows) { row in
                    argumentRow(row.key, row.value)
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Deny", action: deny)
                    .buttonStyle(GlassPillButtonStyle())
                Button("Approve", action: approve)
                    .buttonStyle(GlassPillButtonStyle(prominent: true))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.warm.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.warm.opacity(0.28), lineWidth: 0.75)
        )
    }

    /// One argument as a labeled line. The value is clamped to a few lines so a long
    /// `content` reads as a preview, not a wall — the user can select-all to inspect it.
    private func argumentRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.sans(9.5, weight: .semibold))
                .foregroundStyle(Palette.fg3)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.sans(10.5))
                .foregroundStyle(Palette.fg1)
                .lineLimit(6)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 14)
    }
}
