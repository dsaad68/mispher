import Foundation

/// Whether the Apple Container sandbox capability is on, and what its `container_shell` tool does
/// when the sandbox can't be brought up (the `container` tool isn't installed, the service won't
/// start, or the Mac can't run it). This single field both enables the capability and picks its
/// fail behavior - the `container` capability is off by default since it needs Apple's `container`
/// tool installed.
public enum SandboxMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Off (default) - the agent has no `container_shell` tool.
    case off
    /// On; if the sandbox can't start, run the command in the local shell instead.
    case failover
    /// On; if the sandbox can't start, refuse - never run the command outside the container.
    case containerOnly

    /// Whether the container capability is active.
    public var isEnabled: Bool { self != .off }

    /// A short label for the `/config` editor and prompts.
    public var label: String {
        switch self {
        case .off: "off"
        case .failover: "on - fail over to local shell if unavailable"
        case .containerOnly: "on - container only (fail if unavailable)"
        }
    }
}

/// The user's choices about which deep-agent capabilities run and how their tools are gated -
/// persisted (JSON in `UserDefaults` for the app, a JSON file for ripple) and expanded into the
/// concrete inputs the deep-agent factory understands.
///
/// Everything is keyed by the stable identifiers the agent already uses: middleware by their
/// ``AgentMiddleware/name`` and tools by their dispatch name. Empty sets / maps mean "the
/// defaults" - a fresh `AgentToolPolicy()` reproduces the agent's built-in behavior, so storage
/// only ever records the user's deviations from it.
public struct AgentToolPolicy: Codable, Sendable, Equatable {
    /// Capability middleware the user turned off (by ``AgentMiddleware/name``). A disabled
    /// middleware contributes none of its tools.
    public var disabledMiddleware: Set<String>
    /// Individual tools the user turned off (by dispatch name), independent of their middleware.
    public var disabledTools: Set<String>
    /// Per-tool approval overrides (by dispatch name). A tool absent here uses its default -
    /// the catalog default for a built-in tool, or the caller-supplied default (e.g. an MCP
    /// server's mode) otherwise.
    public var approvals: [String: ToolApprovalMode]
    /// What the `container_shell` tool does when the sandbox is unavailable (see ``SandboxMode``).
    /// Only consulted when the `container` capability is enabled.
    public var sandbox: SandboxMode
    /// The OCI image the sandbox container runs, or nil for the built-in default
    /// (`ghcr.io/astral-sh/uv:python3.13-alpine3.23`).
    public var sandboxImage: String?

    public init(
        disabledMiddleware: Set<String> = [],
        disabledTools: Set<String> = [],
        approvals: [String: ToolApprovalMode] = [:],
        sandbox: SandboxMode = .off,
        sandboxImage: String? = nil
    ) {
        self.disabledMiddleware = disabledMiddleware
        self.disabledTools = disabledTools
        self.approvals = approvals
        self.sandbox = sandbox
        self.sandboxImage = sandboxImage
    }

    /// Decoding tolerates older/partial JSON (any missing field falls back to its default), so a
    /// stored policy keeps loading as the shape grows.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disabledMiddleware = try container.decodeIfPresent(Set<String>.self, forKey: .disabledMiddleware) ?? []
        disabledTools = try container.decodeIfPresent(Set<String>.self, forKey: .disabledTools) ?? []
        approvals = try container.decodeIfPresent([String: ToolApprovalMode].self, forKey: .approvals) ?? [:]
        sandbox = try container.decodeIfPresent(SandboxMode.self, forKey: .sandbox) ?? .off
        sandboxImage = try container.decodeIfPresent(String.self, forKey: .sandboxImage)
    }

    /// Whether the local `shell` tool is active under the sandbox governance: container-only forces
    /// it off, failover forces it on (it's the fallback target), and otherwise the user's
    /// `disabledMiddleware` choice applies. Read by both the deep-agent factory and the `/config`
    /// editor so the two never disagree.
    public var localShellEnabled: Bool {
        switch sandbox {
        case .containerOnly: false
        case .failover: true
        case .off: !disabledMiddleware.contains("shell")
        }
    }

    /// The effective approval for `tool`, resolving the user's override against the given
    /// defaults (the catalog default, then `extraDefaults`, then `.approve`).
    public func mode(for tool: String, extraDefaults: [String: ToolApprovalMode]) -> ToolApprovalMode {
        approvals[tool]
            ?? extraDefaults[tool]
            ?? MiddlewareCatalog.toolDefaults[tool]
            ?? .approve
    }

    /// The concrete inputs the deep-agent factory needs, derived from this policy.
    public struct Expansion: Sendable, Equatable {
        /// Tool names to hide from the agent entirely (disabled tools + every tool of a disabled
        /// middleware).
        public var disabledToolNames: Set<String>
        /// `interruptOn` map for ``HumanInTheLoopMiddleware`` - every tool whose effective mode
        /// is `ask` or `deny`.
        public var interruptOn: [String: InterruptOnConfig]
        /// The subset of `interruptOn` set to `deny`, which the approval handler auto-rejects.
        public var denyToolNames: Set<String>
    }

    /// Expand into `(disabledToolNames, interruptOn, denyToolNames)`.
    ///
    /// - Parameters:
    ///   - catalog: the capability middleware (default ``MiddlewareCatalog/all``); supplies the
    ///     middleware→tools mapping for `disabledMiddleware` and per-tool default approvals.
    ///   - extraDefaults: default approvals for tools outside the catalog - e.g. MCP tools, where
    ///     each server contributes its tools' names and chosen mode.
    public func expand(
        catalog: [MiddlewareDescriptor] = MiddlewareCatalog.all,
        extraDefaults: [String: ToolApprovalMode] = [:]
    ) -> Expansion {
        var disabled = disabledTools
        for middleware in catalog where disabledMiddleware.contains(middleware.id) {
            for tool in middleware.tools { disabled.insert(tool.name) }
        }
        // The sandbox mode governs the local shell, overriding any stale `disabledMiddleware`
        // choice (see `localShellEnabled`): failover forces it on, container-only forces it off.
        // Mirror that here so the tool-name layer agrees with the middleware layer.
        if localShellEnabled { disabled.remove("shell") }

        var catalogDefaults: [String: ToolApprovalMode] = [:]
        for middleware in catalog {
            for tool in middleware.tools { catalogDefaults[tool.name] = tool.defaultApproval }
        }

        // Every tool we might gate: those with a known default, plus any the user named
        // explicitly. Disabled tools are never gated - they aren't exposed at all.
        let candidates = Set(catalogDefaults.keys)
            .union(extraDefaults.keys)
            .union(approvals.keys)
            .subtracting(disabled)

        var interruptOn: [String: InterruptOnConfig] = [:]
        var denyToolNames: Set<String> = []
        for tool in candidates {
            let mode = approvals[tool] ?? extraDefaults[tool] ?? catalogDefaults[tool] ?? .approve
            switch mode {
            case .approve:
                continue
            case .ask:
                interruptOn[tool] = InterruptOnConfig()
            case .deny:
                interruptOn[tool] = InterruptOnConfig()
                denyToolNames.insert(tool)
            }
        }

        return Expansion(
            disabledToolNames: disabled, interruptOn: interruptOn, denyToolNames: denyToolNames
        )
    }

    private enum CodingKeys: String, CodingKey {
        case disabledMiddleware, disabledTools, approvals, sandbox, sandboxImage
    }
}

/// Wrap an approval handler so any tool in `denyToolNames` is rejected immediately, without ever
/// reaching the user. The deny tools are also listed in `interruptOn` (so
/// ``HumanInTheLoopMiddleware`` intercepts the call); this is what turns that interception into a
/// silent rejection. Returns `base` unchanged when nothing is denied.
public func denyEnforcingApprovalHandler(
    _ base: @escaping ToolApprovalHandler, denyToolNames: Set<String>
) -> ToolApprovalHandler {
    guard !denyToolNames.isEmpty else { return base }
    return { request in
        if denyToolNames.contains(request.toolName) {
            return .reject(message: "This tool is set to \"Deny\" in your tool settings.")
        }
        return await base(request)
    }
}
