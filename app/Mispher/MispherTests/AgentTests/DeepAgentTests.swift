import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import Mispher
import Testing

/// `createDeepAgent` composition: the deep agent exposes the planning, filesystem, and task tools
/// together, composes the base prompt with the caller's and the subagent guidance, and honors the
/// feature flags. A recording `FakeChatModel` captures the fully composed request from inside
/// `nextTurn` to inspect what the model was actually offered.
@Suite(.serialized)
struct DeepAgentTests {
    @Test func deepAgentExposesPlanningTaskAndFilesystemTools() async {
        let recorder = RunRecorder()
        let agent = createDeepAgent(
            model: FakeChatModel(answer: "x", recorder: recorder),
            middleware: []
        )
        _ = await agent.collect([.human("hi")])
        let tools = await recorder.toolNameSets.first ?? []
        #expect(tools.contains("write_todos")) // planning pillar
        #expect(tools.contains("task")) // subagents pillar
        #expect(tools.contains("write_file")) // filesystem pillar
    }

    @Test func deepAgentPromptComposesBaseUserAndSubagentGuidance() async {
        let recorder = RunRecorder()
        let researcher = SubAgent(name: "researcher", description: "does research", systemPrompt: "r")
        let agent = createDeepAgent(
            model: FakeChatModel(answer: "x", recorder: recorder),
            systemPrompt: "USER-INSTRUCTIONS-MARKER",
            subagents: [researcher],
            middleware: []
        )
        _ = await agent.collect([.human("hi")])
        let prompt = await recorder.systemPrompts.first ?? nil
        #expect(prompt?.contains("deep agent") == true) // base DeepAgentPrompt
        #expect(prompt?.contains("USER-INSTRUCTIONS-MARKER") == true) // caller's prompt
        #expect(prompt?.contains("researcher") == true) // subagent guidance
    }

    /// Regression for the prompt contradiction that confused the small planner: the base
    /// prompt used to end with "Skip the ceremony for simple requests" while the screen
    /// agent's prompt mandated "Plan first, always" and told the model to ignore the
    /// former. The composed deep-screen prompt must now carry exactly one planning policy.
    @Test func deepScreenPromptCarriesASinglePlanningPolicy() async {
        let recorder = RunRecorder()
        let agent = createDeepAgent(
            model: FakeChatModel(answer: "x", recorder: recorder),
            systemPrompt: DeepScreenPrompt.system,
            middleware: []
        )
        _ = await agent.collect([.human("hi")])
        let prompt = await (recorder.systemPrompts.first ?? nil) ?? ""
        #expect(prompt.contains("Plan first, always")) // the screen agent's policy…
        #expect(!prompt.contains("Skip the ceremony")) // …with no competing escape hatch
        #expect(!prompt.contains("Skip the tool")) // (middleware guidance is policy-free)
        #expect(!prompt.contains("Ignore any guidance")) // no override needed anymore
    }

    @Test func includeFilesystemFalseOmitsFilesystemTools() async {
        let recorder = RunRecorder()
        let agent = createDeepAgent(
            model: FakeChatModel(answer: "x", recorder: recorder),
            middleware: [],
            includeFilesystem: false
        )
        _ = await agent.collect([.human("hi")])
        let tools = await recorder.toolNameSets.first ?? []
        #expect(!tools.contains("write_file"))
        #expect(tools.contains("task")) // subagents pillar still present
        #expect(tools.contains("write_todos")) // planning pillar still present
        // The base prompt must not tell the model to use a tool that isn't registered.
        let prompt = await (recorder.systemPrompts.first ?? nil) ?? ""
        #expect(!prompt.contains("write_file"))
    }

    /// `MispherDeepAgent` composition: the production deep agent carries the three
    /// pillars plus screen capture, the clipboard, and Apple Notes, and every tool arrives
    /// via the middleware that owns it (so its guidance section comes along).
    @Test func mispherDeepAgentIncludesScreenshotAndClipboardTools() {
        let agent = MispherDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "x", supportsVision: true)
        )
        let tools = agent.tools.map(\.name)
        #expect(tools.contains("take_screenshot"))
        #expect(tools.contains("take_window_screenshots"))
        #expect(tools.contains("read_clipboard"))
        #expect(tools.contains("write_clipboard"))
        #expect(tools.contains("write_todos")) // planning pillar
        #expect(tools.contains("task")) // subagents pillar
        #expect(tools.contains("write_file")) // filesystem pillar
        #expect(tools.contains("list_notes")) // Apple Notes middleware
        #expect(tools.contains("create_note"))
        #expect(tools.contains("update_note"))
    }

    /// Vision "None": with no vision model the planner runs blind — the vision subagent and the
    /// screen-capture tools that feed it are both dropped, while the other capabilities remain.
    @Test func mispherDeepAgentWithoutVisionDropsScreenCapture() {
        let agent = MispherDeepAgent.make(textModel: FakeChatModel(answer: "x"))
        let tools = agent.tools.map(\.name)
        #expect(!tools.contains("take_screenshot"))
        #expect(!tools.contains("take_window_screenshots"))
        #expect(tools.contains("read_clipboard")) // other capabilities unaffected
        #expect(tools.contains("write_todos")) // planning pillar still present
    }

    /// Regression: on the real-disk backend every filesystem tool needs the user's sign-off,
    /// `ls` included - listing real paths can reveal sensitive file and folder names under the
    /// user's home, so it is gated alongside the reads and writes rather than running free.
    @Test func mispherDeepAgentGatesEveryRealDiskFilesystemTool() {
        #expect(Set(MispherDeepAgent.fileApprovals.keys) == ["ls", "read_file", "write_file", "edit_file"])
    }

    /// Regression: Apple Notes writes are gated like file writes - `create_note`/`update_note`
    /// need the user's sign-off (the approval card shows the title/body), while reads stay free.
    @Test func mispherDeepAgentGatesNotesWrites() {
        #expect(Set(MispherDeepAgent.notesApprovals.keys) == ["create_note", "update_note"])
    }

    /// Regression: tool approvals are keyed by run scope, so two in-flight runs (e.g. the Ask
    /// flow and a HUD chat) don't reject each other's pending approval. Resolving one scope must
    /// leave another's request suspended and deliver that scope's own decision.
    @MainActor @Test func toolApprovalsAreScopedPerRun() async {
        let manager = MlxModelManager()
        let request = ToolApprovalRequest(
            id: UUID(), toolName: "read_file", arguments: [:],
            description: "read", allowedDecisions: [.approve, .reject]
        )

        // Run A suspends awaiting approval under its own scope.
        let runA = Task { await manager.requestToolApproval(request, scope: "thread-A") }
        while manager.pendingToolApproval(for: "thread-A") == nil { await Task.yield() }

        // A different run resolving its (empty) scope must not touch run A.
        manager.resolveToolApproval(.reject(message: nil), scope: "thread-B")
        #expect(manager.pendingToolApproval(for: "thread-A") != nil)

        // Resolving A's scope delivers A's own decision, not the other run's rejection.
        manager.resolveToolApproval(.approve, scope: "thread-A")
        let decisionA = await runA.value
        #expect(decisionA.type == .approve)
        #expect(manager.pendingToolApproval(for: "thread-A") == nil)
    }

    @Test func includeGeneralPurposeFalseRemovesItFromRegistry() async {
        let taskCall = AgentToolCall(
            name: "task",
            arguments: ["description": .string("x"), "subagent_type": .string("general-purpose")]
        )
        let agent = createDeepAgent(
            model: FakeChatModel(answer: "done", toolCalls: [taskCall]),
            includeGeneralPurpose: false
        )
        let (ok, events) = await agent.collect([.human("go")])
        #expect(ok)
        let result = events.toolCompletedResults.first { $0.name == "task" }?.result ?? ""
        #expect(result.contains("unknown subagent")) // general-purpose is no longer registered
    }
}
