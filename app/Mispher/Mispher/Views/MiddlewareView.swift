import DeepAgents
import DeepAgentsMLX
import SwiftUI

/// Settings panel listing the deep agent's capability middleware (``MiddlewareCatalog``): turn a
/// capability on or off, hide individual tools, and set each tool's approval to Approve / Ask /
/// Deny. Choices are persisted on ``TranscriptionViewModel/agentToolPolicy`` and applied the next
/// time the deep agent is built. Speaks the same glass language as the other Settings tabs.
///
/// Only **capability** middleware appear here; the agent's scaffolding (planning, subagents) is
/// always on, and MCP servers are configured in their own tab.
struct MiddlewareView: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Capabilities")

                Text(
                    "Choose which capabilities the deep agent can use, hide individual tools, and "
                        + "set whether each tool runs automatically, asks you first, or is always denied."
                )
                .font(.sans(11.5))
                .foregroundStyle(Palette.fg2)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(MiddlewareCatalog.all) { descriptor in
                    SettingsCard {
                        MiddlewareCard(descriptor: descriptor, policy: $vm.agentToolPolicy)
                    }
                }
            }
        }
    }
}

/// One capability middleware: a header (icon, name, summary, master enable toggle) and, when
/// enabled, an expandable list of its tools.
private struct MiddlewareCard: View {
    let descriptor: MiddlewareDescriptor
    @Binding var policy: AgentToolPolicy
    @State private var expanded = false

    private var isEnabled: Bool { !policy.disabledMiddleware.contains(descriptor.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: descriptor.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(isEnabled ? Palette.accent : Palette.fg3)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName)
                        .font(.sans(12.5, weight: .medium))
                        .foregroundStyle(Palette.fg)
                    Text(descriptor.summary)
                        .font(.sans(11))
                        .foregroundStyle(Palette.fg2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("", isOn: enabledBinding)
                    .toggleStyle(GlassToggleStyle())
                    .labelsHidden()
                    // GlassToggleStyle has an internal greedy Spacer; size the toggle to its content
                    // here so it doesn't split the row with the description (which then gets the width).
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Enable \(descriptor.displayName)")
            }

            if isEnabled {
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(descriptor.tools.count) tools")
                            .font(.sans(11, weight: .medium))
                    }
                    .foregroundStyle(Palette.fg3)
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(descriptor.tools) { tool in
                            ToolRow(tool: tool, policy: $policy)
                        }
                    }
                    .padding(.leading, 28)
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { !policy.disabledMiddleware.contains(descriptor.id) },
            set: { on in
                if on {
                    policy.disabledMiddleware.remove(descriptor.id)
                } else {
                    policy.disabledMiddleware.insert(descriptor.id)
                }
            }
        )
    }
}

/// One tool within a capability: an enable toggle and, when enabled, an Approve / Ask / Deny
/// picker. A disabled tool is hidden from the agent entirely, so its approval picker is dimmed.
private struct ToolRow: View {
    let tool: ToolDescriptor
    @Binding var policy: AgentToolPolicy

    private var isEnabled: Bool { !policy.disabledTools.contains(tool.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.displayName)
                        .font(.sans(12, weight: .medium))
                        .foregroundStyle(isEnabled ? Palette.fg : Palette.fg3)
                    Text(tool.summary)
                        .font(.sans(10.5))
                        .foregroundStyle(Palette.fg2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("", isOn: enabledBinding)
                    .toggleStyle(GlassToggleStyle())
                    .labelsHidden()
                    // GlassToggleStyle has an internal greedy Spacer; size the toggle to its content
                    // here so it doesn't split the row with the description (which then gets the width).
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Enable \(tool.displayName)")
            }

            GlassSegmented(
                options: [
                    (ToolApprovalMode.approve, ToolApprovalMode.approve.label),
                    (.ask, ToolApprovalMode.ask.label),
                    (.deny, ToolApprovalMode.deny.label)
                ],
                selection: approvalBinding
            )
            .accessibilityLabel("Approval for \(tool.displayName)")
            .opacity(isEnabled ? 1 : 0.35)
            .disabled(!isEnabled)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { !policy.disabledTools.contains(tool.name) },
            set: { on in
                if on {
                    policy.disabledTools.remove(tool.name)
                } else {
                    policy.disabledTools.insert(tool.name)
                }
            }
        )
    }

    private var approvalBinding: Binding<ToolApprovalMode> {
        Binding(
            get: { policy.approvals[tool.name] ?? tool.defaultApproval },
            set: { policy.approvals[tool.name] = $0 }
        )
    }
}
