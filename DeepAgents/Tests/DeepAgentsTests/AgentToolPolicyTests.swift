@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

// Tests for the tool-policy layer: how an `AgentToolPolicy` expands into the deep-agent
// factory's inputs (disabled tools, the `interruptOn` gate map, the deny set), and how the
// deny-enforcing approval handler short-circuits.

@Suite("AgentToolPolicy.expand")
struct AgentToolPolicyExpandTests {
    @Test("Defaults gate writes, leave reads ungated, disable nothing")
    func defaults() {
        let expansion = AgentToolPolicy().expand()

        #expect(expansion.disabledToolNames.isEmpty)
        #expect(expansion.denyToolNames.isEmpty)
        // Catalog defaults: file tools + notes writes are `ask`; notes/clipboard/screenshot
        // reads are `approve` (ungated).
        #expect(expansion.interruptOn["write_file"] != nil)
        #expect(expansion.interruptOn["edit_file"] != nil)
        #expect(expansion.interruptOn["create_note"] != nil)
        #expect(expansion.interruptOn["update_note"] != nil)
        #expect(expansion.interruptOn["read_note"] == nil)
        #expect(expansion.interruptOn["read_clipboard"] == nil)
        #expect(expansion.interruptOn["take_screenshot"] == nil)
    }

    @Test("Disabling a middleware hides all its tools and never gates them")
    func disabledMiddleware() {
        let policy = AgentToolPolicy(disabledMiddleware: ["filesystem"])
        let expansion = policy.expand()

        for tool in ["ls", "read_file", "write_file", "edit_file"] {
            #expect(expansion.disabledToolNames.contains(tool))
            #expect(expansion.interruptOn[tool] == nil) // disabled tools are not gated
        }
        // A different middleware's gating is untouched.
        #expect(expansion.interruptOn["create_note"] != nil)
    }

    @Test("Disabling a single tool hides just that tool")
    func disabledTool() {
        let expansion = AgentToolPolicy(disabledTools: ["write_clipboard"]).expand()

        #expect(expansion.disabledToolNames == ["write_clipboard"])
        #expect(expansion.interruptOn["write_clipboard"] == nil)
    }

    @Test("Per-tool overrides win over catalog defaults")
    func overrides() {
        let policy = AgentToolPolicy(approvals: [
            "read_file": .approve, // loosen a default-ask tool
            "write_clipboard": .deny, // tighten a default-approve tool
            "read_clipboard": .ask
        ])
        let expansion = policy.expand()

        #expect(expansion.interruptOn["read_file"] == nil) // now ungated
        #expect(expansion.interruptOn["write_clipboard"] != nil)
        #expect(expansion.denyToolNames.contains("write_clipboard"))
        #expect(expansion.interruptOn["read_clipboard"] != nil)
        #expect(!expansion.denyToolNames.contains("read_clipboard"))
    }

    @Test("MCP tools gate via extraDefaults and respect per-tool overrides")
    func extraDefaults() {
        let policy = AgentToolPolicy(approvals: ["search__fetch": .approve])
        let expansion = policy.expand(extraDefaults: [
            "search__web_search": .ask,
            "search__fetch": .ask // overridden to approve below
        ])

        #expect(expansion.interruptOn["search__web_search"] != nil)
        #expect(expansion.interruptOn["search__fetch"] == nil) // override to approve wins
    }

    @Test("Policy round-trips through JSON and tolerates missing fields")
    func codable() throws {
        let policy = AgentToolPolicy(
            disabledMiddleware: ["clipboard"], approvals: ["write_file": .deny]
        )
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(AgentToolPolicy.self, from: data)
        #expect(decoded == policy)

        // A partial blob (only one field present) still decodes.
        let partial = Data(#"{"disabledTools":["ls"]}"#.utf8)
        let fromPartial = try JSONDecoder().decode(AgentToolPolicy.self, from: partial)
        #expect(fromPartial.disabledTools == ["ls"])
        #expect(fromPartial.disabledMiddleware.isEmpty)
        #expect(fromPartial.approvals.isEmpty)
    }
}

@Suite("denyEnforcingApprovalHandler")
struct DenyEnforcingHandlerTests {
    private func request(_ tool: String) -> ToolApprovalRequest {
        ToolApprovalRequest(
            id: UUID(), toolName: tool, arguments: [:],
            description: "test", allowedDecisions: [.approve, .reject]
        )
    }

    @Test("Denied tools are rejected without calling the base handler")
    func deniesWithoutPrompting() async {
        let baseCalled = Mutable(false)
        let base: ToolApprovalHandler = { _ in baseCalled.value = true; return .approve }
        let handler = denyEnforcingApprovalHandler(base, denyToolNames: ["write_file"])

        let decision = await handler(request("write_file"))
        if case .reject = decision {} else { Issue.record("expected reject, got \(decision)") }
        #expect(baseCalled.value == false)
    }

    @Test("Non-denied tools pass through to the base handler")
    func passesThrough() async {
        let baseCalled = Mutable(false)
        let base: ToolApprovalHandler = { _ in baseCalled.value = true; return .approve }
        let handler = denyEnforcingApprovalHandler(base, denyToolNames: ["write_file"])

        let decision = await handler(request("read_file"))
        if case .approve = decision {} else { Issue.record("expected approve, got \(decision)") }
        #expect(baseCalled.value == true)
    }

    @Test("Empty deny set returns the base handler unchanged in behavior")
    func emptyDenySet() async {
        let base: ToolApprovalHandler = { _ in .approve }
        let handler = denyEnforcingApprovalHandler(base, denyToolNames: [])
        let decision = await handler(request("anything"))
        if case .approve = decision {} else { Issue.record("expected approve") }
    }
}

/// A tiny reference box so a closure can record that it ran (the handler closures are
/// `@Sendable`, so they can't capture a `var` directly).
private final class Mutable<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
