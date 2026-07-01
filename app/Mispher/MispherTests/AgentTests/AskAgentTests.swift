import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import Mispher
import Testing

/// `AskAgent` in isolation: it composes the todo/clipboard/utility tools and the Ask system
/// prompt, and supports both single-turn and multi-turn (memory) runs — all asserted with a
/// scripted `FakeChatModel`, no model download.
@Suite(.serialized)
struct AskAgentTests {
    /// Build the agent from the definition's public surface plus a trailing recorder. The
    /// recorder is registered last → innermost, so it captures the fully composed request
    /// (after every middleware's `wrapModelCall` override).
    private func recordingAgent(memory: (any AgentCheckpointer)? = nil) -> (ReactAgent, RunRecorder) {
        let recorder = RunRecorder()
        let agent = createAgent(
            model: FakeChatModel(answer: "done", recorder: recorder),
            systemPrompt: AskAgent.systemPrompt,
            middleware: AskAgent.middleware(),
            memory: memory
        )
        return (agent, recorder)
    }

    @Test func composesAllTextTools() async {
        let (agent, recorder) = recordingAgent()
        _ = await agent.collect([.human("hi")])
        let tools = await (recorder.toolNameSets.first ?? []).sorted()
        #expect(
            tools == [
                "calculator", "current_datetime", "read_clipboard", "write_clipboard",
                "write_todos"
            ]
        )
    }

    @Test func hasNoScreenshotTool() async {
        let (agent, recorder) = recordingAgent()
        _ = await agent.collect([.human("hi")])
        #expect(await !(recorder.toolNameSets.first ?? []).contains("take_screenshot"))
    }

    @Test func usesAskPrompt() async {
        let (agent, recorder) = recordingAgent()
        _ = await agent.collect([.human("hi")])
        let sys = await (recorder.systemPrompts.first ?? nil) ?? ""
        #expect(sys.contains(AskPrompt.system))
    }

    /// Drift guard: every tool offered to the model must be covered by guidance in the
    /// composed system prompt — contributed by the middleware that owns the tool, never
    /// hardcoded in the agent prompt. This fails the moment someone adds a
    /// tool-contributing middleware without a guidance section (the old hardcoded
    /// "Your tools are: …" list silently omitted newly added tools).
    @Test func everyOfferedToolIsMentionedInTheComposedPrompt() async {
        let (agent, recorder) = recordingAgent()
        _ = await agent.collect([.human("hi")])
        let sys = await (recorder.systemPrompts.first ?? nil) ?? ""
        let tools = await recorder.toolNameSets.first ?? []
        for tool in tools {
            #expect(sys.contains(tool), "tool '\(tool)' offered but never mentioned in the prompt")
        }
    }

    @Test func supportsMultiTurnMemory() async {
        let memory = InMemoryCheckpointer()
        let (agent, recorder) = recordingAgent(memory: memory)
        _ = await agent.collect([.human("first")], threadId: "t")
        _ = await agent.collect([.human("second")], threadId: "t")
        // Round 2 replays the prior human+ai turns, so the assembled request grows.
        #expect(await recorder.messageCounts == [1, 3])
    }
}
