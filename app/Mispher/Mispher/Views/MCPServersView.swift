import DeepAgents
import MCP
import SwiftUI

/// Settings panel for configuring MCP servers the agent can load tools from. Each server
/// is persisted (via `TranscriptionViewModel.mcpServers`) and, at agent-build time, turned
/// into a `MultiServerMCPClient` whose tools are handed to the agent. Speaks the same glass
/// design language as the other Settings tabs (`SettingsCard`, `SectionLabel`, `Palette`).
struct MCPServersView: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Servers")

                if vm.mcpServers.isEmpty {
                    SettingsCard {
                        Text(
                            "No MCP servers yet. Add a local (stdio) or remote (HTTP) server "
                                + "to give the agent its tools. Tools are namespaced as server__tool."
                        )
                        .font(.sans(11.5))
                        .foregroundStyle(Palette.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach($vm.mcpServers) { $server in
                        SettingsCard {
                            MCPServerEditor(server: $server) {
                                // Read the id *before* mutating: `server` is the ForEach
                                // binding's wrapped value, so reading `server.id` inside
                                // `removeAll`'s predicate would read back through
                                // `vm.mcpServers` while `removeAll` holds exclusive write
                                // access to it — a Swift exclusivity violation (crash).
                                let id = server.id
                                vm.mcpServers.removeAll { $0.id == id }
                            }
                        }
                    }
                }
            }

            Button {
                vm.mcpServers.append(
                    MCPServerConfig(name: Self.uniqueName(in: vm.mcpServers), kind: .stdio)
                )
            } label: {
                Label("Add Server", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
        }
    }

    /// A default server name not already used, so newly-added servers don't collide (tool
    /// names are namespaced by server name, and a collision would shadow the later server).
    static func uniqueName(in servers: [MCPServerConfig], base: String = "new-server") -> String {
        let existing = Set(servers.map(\.name))
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }
}

// MARK: - Connection probe model

/// A tool discovered by a successful "Connect" probe, projected into plain `Sendable` value
/// types so the UI never has to touch the MCP SDK's `Value`/`Tool` types directly.
private struct DiscoveredTool: Identifiable, Sendable {
    let id = UUID()
    /// The tool's name on the server.
    let name: String
    /// The namespaced `server__tool` name the agent actually dispatches on.
    let dispatchName: String
    let description: String
    let parameters: [ToolParam]
}

/// One entry from a tool's input JSON Schema, flattened for display.
private struct ToolParam: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let type: String
    let isRequired: Bool
    let description: String
}

/// The lifecycle of the per-server "Connect" probe.
private enum ProbeState {
    case idle
    case connecting
    case connected([DiscoveredTool])
    case failed(String)
}

/// Editor for a single MCP server: name, transport, enable toggle, and the per-transport
/// connection fields (command/args/env for stdio, url/headers for http).
///
/// A "Connect" button probes the server live: on success the connection fields collapse and
/// the server's advertised tools are listed (tap one for its full description and parameters
/// in a dialog); on failure an inline message explains what went wrong.
private struct MCPServerEditor: View {
    @Binding var server: MCPServerConfig
    let onDelete: () -> Void

    /// The model manager owns the agent's live (warm) MCP client; this view reflects its tools
    /// directly rather than opening its own connection.
    @Environment(MlxModelManager.self) private var mlx

    @State private var probe: ProbeState = .idle
    @State private var probeTask: Task<Void, Never>?
    /// The tool whose detail dialog is open, if any.
    @State private var detailTool: DiscoveredTool?
    /// Whether an OAuth token is cached for this server (drives the "Signed in" status).
    @State private var isSignedIn = false
    /// User tapped "Edit" to reveal the connection fields even though the server is connected.
    @State private var editing = false
    /// Whether the discovered-tools list is expanded (collapsed by default).
    @State private var toolsExpanded = false

    /// Keychain store for this server's OAuth token, keyed by its id.
    private var tokenStore: KeychainTokenStorage { KeychainTokenStorage(serverID: server.id.uuidString) }

    /// The tools the agent's warm client loaded for *this* server (matched by the namespaced
    /// `server__tool` prefix), projected for display. Empty when the server isn't in the live set
    /// (disabled, not-yet-signed-in OAuth, or failed to connect).
    private var warmTools: [DiscoveredTool] {
        mcpToolsForDisplay(server: server.name, in: mlx.mcpWarmTools).map {
            DiscoveredTool(
                name: $0.name,
                dispatchName: $0.dispatchName,
                description: $0.description,
                parameters: Self.parameters(from: $0.schema)
            )
        }
    }

    /// What to display as "connected": a manual probe's result if one ran, else the agent's live
    /// warm tools. `nil` means the server isn't connected, so show the editable fields.
    private var shownTools: [DiscoveredTool]? {
        if case .connected(let tools) = probe { return tools }
        return warmTools.isEmpty ? nil : warmTools
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GlassTextField(placeholder: "Name", text: $server.name, fontSize: 12.5)
                    .frame(maxWidth: 200)

                GlassSegmented(
                    options: [(.stdio, "stdio"), (.http, "HTTP")],
                    selection: $server.kind
                )
                .accessibilityLabel("Transport")

                Spacer(minLength: 8)

                Toggle("", isOn: $server.isEnabled)
                    .toggleStyle(GlassToggleStyle())
                    .labelsHidden()
                    .accessibilityLabel("Enabled")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.fg2)
                .accessibilityLabel("Remove server")
            }

            // How this server's tools are gated. MCP tools are outward-facing (they do whatever
            // the server does), so the default is Ask; trusted read-only servers can be set to
            // Approve, and a server can be blocked outright with Deny.
            HStack(spacing: 10) {
                Text("Tool approval")
                    .font(.sans(11, weight: .medium))
                    .foregroundStyle(Palette.fg2)
                GlassSegmented(
                    options: [
                        (ToolApprovalMode.approve, ToolApprovalMode.approve.label),
                        (.ask, ToolApprovalMode.ask.label),
                        (.deny, ToolApprovalMode.deny.label)
                    ],
                    selection: $server.approvalMode
                )
                .accessibilityLabel("Tool approval")
                Spacer(minLength: 8)
            }

            // When the agent has this server connected (its warm tools, or a manual probe), the
            // connection fields collapse to that live tool list; otherwise show the editable fields
            // plus the Connect control. "Edit" forces the fields back even while connected.
            if !editing, let tools = shownTools {
                connectedView(tools)
            } else {
                connectionFields
                footer
            }
        }
        // Switching transport invalidates any probe result (the fields it was built from are
        // now hidden), so fall back to the editable state and let the user reconnect.
        .onChange(of: server.kind) { resetProbe(); editing = false }
        .onAppear { isSignedIn = tokenStore.hasToken }
        .onChange(of: server.auth) { isSignedIn = tokenStore.hasToken }
        .onDisappear { probeTask?.cancel() }
        .sheet(item: $detailTool) { tool in
            MCPToolDetailSheet(tool: tool) { detailTool = nil }
        }
    }

    // MARK: Connection fields

    @ViewBuilder private var connectionFields: some View {
        switch server.kind {
        case .stdio:
            field("Command", text: $server.command, placeholder: "/opt/homebrew/bin/npx")
            Text(
                "Use an absolute path. GUI apps don't inherit your shell's PATH, "
                    + "so a bare name like \"npx\" may not resolve - or add PATH below under Environment."
            )
            .font(.sans(10))
            .foregroundStyle(Palette.fg3)
            .fixedSize(horizontal: false, vertical: true)
            linesField(
                "Arguments (one per line)", lines: $server.args,
                placeholder: "-y\n@modelcontextprotocol/server-filesystem"
            )
            pairsField(
                "Environment (KEY=VALUE, one per line)", pairs: $server.env,
                separator: "=", joiner: "=", placeholder: "API_KEY=…"
            )
        case .http:
            field("URL", text: $server.url, placeholder: "https://example.com/mcp")
            HStack(spacing: 10) {
                Text("Authentication")
                    .font(.sans(11, weight: .medium))
                    .foregroundStyle(Palette.fg2)
                GlassSegmented(
                    options: [(MCPServerConfig.Auth.none, "Headers"), (.oauth, "OAuth")],
                    selection: $server.auth
                )
                .accessibilityLabel("Authentication")
                Spacer(minLength: 8)
            }
            if server.auth == .oauth { oauthStatus }
            pairsField(
                "Headers (Key: Value, one per line)", pairs: $server.headers,
                separator: ":", joiner: ": ", placeholder: "Authorization: Bearer …"
            )
        }
    }

    /// OAuth sign-in status for an `oauth` server. Connecting runs the browser sign-in (the SDK
    /// triggers it on the first request); the token is then cached in the Keychain.
    private var oauthStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: isSignedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 11))
                .foregroundStyle(isSignedIn ? Palette.accent : Palette.fg3)
            Text(
                isSignedIn
                    ? "Signed in. Mispher reuses the saved token."
                    : "Not signed in. Connecting opens your browser to sign in."
            )
            .font(.sans(10.5))
            .foregroundStyle(Palette.fg2)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if isSignedIn {
                Button("Sign out") {
                    tokenStore.clear()
                    isSignedIn = false
                }
                .buttonStyle(.plain)
                .font(.sans(10.5, weight: .medium))
                .foregroundStyle(Palette.accent)
            }
        }
    }

    // MARK: Connect control + status

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            connectButton
            if case .connecting = probe {
                ProgressView()
                    .controlSize(.small)
                    .tint(Palette.accent)
                Text("Connecting…")
                    .font(.sans(10.5))
                    .foregroundStyle(Palette.fg2)
            }
            Spacer(minLength: 8)
        }

        if case .failed(let message) = probe {
            errorBanner(message)
        }
    }

    private var connectButton: some View {
        Button(action: connect) {
            Label(probe.isFailed ? "Reconnect" : "Connect", systemImage: "bolt.horizontal.fill")
        }
        .buttonStyle(GlassPillButtonStyle(prominent: true))
        .disabled(probe.isConnecting)
        .accessibilityLabel("Connect to server and list tools")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.recRed)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't connect")
                    .font(.sans(11, weight: .semibold))
                    .foregroundStyle(Palette.fg)
                Text(message)
                    .font(.sans(10.5))
                    .foregroundStyle(Palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.recRed.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.recRed.opacity(0.28), lineWidth: 0.75)
        )
    }

    // MARK: Connected — discovered tools

    private func connectedView(_ tools: [DiscoveredTool]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.success)
                Text(connectedSummary(count: tools.count))
                    .font(.sans(11.5, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Spacer(minLength: 8)
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(GlassPillButtonStyle())
                .disabled(mlx.mcpWarming)
                Button { resetProbe(); editing = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(GlassPillButtonStyle())
            }

            if tools.isEmpty {
                Text("This server connected but advertised no tools.")
                    .font(.sans(10.5))
                    .foregroundStyle(Palette.fg2)
            } else {
                Button { withAnimation(.easeInOut(duration: 0.15)) { toolsExpanded.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: toolsExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Tools")
                            .font(.sans(11, weight: .medium))
                    }
                    .foregroundStyle(Palette.fg3)
                }
                .buttonStyle(.plain)

                if toolsExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                            if index > 0 {
                                Rectangle().fill(Palette.border).frame(height: 1)
                            }
                            toolRow(tool)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.03)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: 0.75)
                    )
                }
            }
        }
    }

    private func toolRow(_ tool: DiscoveredTool) -> some View {
        Button { detailTool = tool } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.mono(11.5, weight: .medium))
                        .foregroundStyle(Palette.fg)
                    if !tool.description.isEmpty {
                        Text(tool.description)
                            .font(.sans(10.5))
                            .foregroundStyle(Palette.fg2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.fg3)
                    .padding(.top, 1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Show full description and parameters")
    }

    private func connectedSummary(count: Int) -> String {
        switch count {
        case 0: return "Connected"
        case 1: return "Connected · 1 tool"
        default: return "Connected · \(count) tools"
        }
    }

    // MARK: Probe

    /// Open a one-shot session to the configured server, list its tools, then disconnect —
    /// purely to validate the configuration and show the user what the agent will see. The
    /// agent builds its own long-lived sessions separately (see `MultiServerMCPClient`).
    private func connect() {
        probeTask?.cancel()
        probe = .connecting
        let config = server
        probeTask = Task {
            let session = SwiftSDKMCPSession(config: config)
            do {
                try await session.connect()
                let tools = try await session.listTools()
                await session.disconnect()
                if Task.isCancelled { return }
                let discovered = tools.map { tool in
                    DiscoveredTool(
                        name: tool.name,
                        dispatchName: MCPTool.dispatchName(server: config.name, tool: tool.name),
                        description: tool.description ?? "",
                        parameters: Self.parameters(from: MCPValueBridge.schemaObject(tool.inputSchema))
                    )
                }
                probe = .connected(discovered)
                isSignedIn = tokenStore.hasToken // a successful OAuth connect cached a token
                editing = false
                // Fold this server into the agent's live client (it now connects - e.g. OAuth is
                // signed in), so the agent and this view share one connection going forward.
                Task { await mlx.warmMCP() }
            } catch {
                await session.disconnect()
                if Task.isCancelled { return }
                probe = .failed(error.localizedDescription)
            }
        }
    }

    private func resetProbe() {
        probeTask?.cancel()
        probeTask = nil
        probe = .idle
    }

    /// Re-warm the agent's live MCP client so its tool list reflects the current config, and drop
    /// any stale manual-probe result so the view falls back to that live set. This reconnects the
    /// *same* client the agent uses - not a throwaway probe.
    private func refresh() {
        resetProbe()
        Task { await mlx.warmMCP() }
    }

    /// Flatten a tool's input JSON Schema (already projected to native `Sendable` values by
    /// `MCPValueBridge.schemaObject`) into a sorted, displayable parameter list.
    private static func parameters(from schema: [String: any Sendable]) -> [ToolParam] {
        let properties = schema["properties"] as? [String: any Sendable] ?? [:]
        let required = Set((schema["required"] as? [any Sendable] ?? []).compactMap { $0 as? String })
        return properties.keys.sorted().map { key in
            let prop = properties[key] as? [String: any Sendable] ?? [:]
            return ToolParam(
                name: key,
                type: typeLabel(prop["type"]),
                isRequired: required.contains(key),
                description: prop["description"] as? String ?? ""
            )
        }
    }

    /// A JSON Schema `type` is usually a string, but may be an array of strings (a union).
    private static func typeLabel(_ value: (any Sendable)?) -> String {
        if let string = value as? String { return string }
        if let array = value as? [any Sendable] {
            return array.compactMap { $0 as? String }.joined(separator: " | ")
        }
        return ""
    }

    // MARK: - Field helpers

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.sans(10.5, weight: .medium))
                .foregroundStyle(Palette.fg3)
            GlassTextField(placeholder: placeholder, text: text)
        }
    }

    /// A newline-delimited editor over a `[String]` (e.g. process arguments).
    private func linesField(
        _ label: String, lines: Binding<[String]>, placeholder: String
    ) -> some View {
        let text = Binding(
            get: { lines.wrappedValue.joined(separator: "\n") },
            set: { lines.wrappedValue = Self.splitLines($0) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.sans(10.5, weight: .medium))
                .foregroundStyle(Palette.fg3)
            GlassTextField(placeholder: placeholder, text: text, axis: .vertical, lineLimit: 2 ... 6)
        }
    }

    /// A newline-delimited editor over a `[String: String]`, each line `key<sep>value`.
    /// `separator` is the char that splits a line on input; `joiner` is how a pair is
    /// rendered back out (e.g. `=` for env vars, `: ` for headers), so the displayed text
    /// matches each field's documented convention.
    private func pairsField(
        _ label: String, pairs: Binding<[String: String]>, separator: Character,
        joiner: String, placeholder: String
    ) -> some View {
        let text = Binding(
            get: { Self.formatPairs(pairs.wrappedValue, joiner: joiner) },
            set: { pairs.wrappedValue = Self.parsePairs($0, separator: separator) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.sans(10.5, weight: .medium))
                .foregroundStyle(Palette.fg3)
            GlassTextField(placeholder: placeholder, text: text, axis: .vertical, lineLimit: 1 ... 5)
        }
    }

    // MARK: - Text <-> model helpers

    private static func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func formatPairs(_ pairs: [String: String], joiner: String) -> String {
        pairs.sorted { $0.key < $1.key }
            .map { "\($0.key)\(joiner)\($0.value)" }
            .joined(separator: "\n")
    }

    private static func parsePairs(_ text: String, separator: Character) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let index = line.firstIndex(of: separator) else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

private extension ProbeState {
    var isConnecting: Bool { if case .connecting = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

// MARK: - Tool detail dialog

/// A dialog showing one discovered tool in full: its server-side name, the namespaced name
/// the agent dispatches on, the description, and every input parameter with its type.
private struct MCPToolDetailSheet: View {
    let tool: DiscoveredTool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accent)
                Text(tool.name)
                    .font(.mono(13, weight: .semibold))
                    .foregroundStyle(Palette.fg)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Text("Done")
                        .font(.sans(11.5, weight: .medium))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Rectangle().fill(Palette.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    block("Agent tool name") {
                        Text(tool.dispatchName)
                            .font(.mono(11.5))
                            .foregroundStyle(Palette.fg1)
                            .textSelection(.enabled)
                    }

                    if !tool.description.isEmpty {
                        block("Description") {
                            Text(tool.description)
                                .font(.sans(12))
                                .foregroundStyle(Palette.fg1)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }

                    block("Parameters") {
                        if tool.parameters.isEmpty {
                            Text("No parameters.")
                                .font(.sans(11.5))
                                .foregroundStyle(Palette.fg2)
                        } else {
                            VStack(alignment: .leading, spacing: 11) {
                                ForEach(tool.parameters) { param in
                                    paramRow(param)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 440)
        .background(Palette.bgDeep)
    }

    private func block(
        _ label: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            content()
        }
    }

    private func paramRow(_ param: ToolParam) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(param.name)
                    .font(.mono(11.5, weight: .medium))
                    .foregroundStyle(Palette.fg)
                if !param.type.isEmpty {
                    Badge(text: param.type, tint: Palette.fg2)
                }
                if param.isRequired {
                    Badge(text: "required", tint: Palette.warm)
                }
            }
            if !param.description.isEmpty {
                Text(param.description)
                    .font(.sans(11))
                    .foregroundStyle(Palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
