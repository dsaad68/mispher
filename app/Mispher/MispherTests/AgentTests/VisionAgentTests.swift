import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import Mispher
import Testing

/// `VisionAgent` in isolation: only the screenshot tool, and a system prompt that is the
/// vision prompt plus the screenshot middleware's appended guidance. Locks in the
/// narrowing — vision models do NOT get the text tools.
@Suite(.serialized)
struct VisionAgentTests {
    private func recordingAgent() -> (ReactAgent, RunRecorder) {
        let recorder = RunRecorder()
        let agent = createAgent(
            model: FakeChatModel(answer: "I see a window.", supportsVision: true, recorder: recorder),
            systemPrompt: VisionAgent.systemPrompt,
            middleware: VisionAgent.middleware()
        )
        return (agent, recorder)
    }

    @Test func composesOnlyScreenshotTools() async {
        let (agent, recorder) = recordingAgent()
        _ = await agent.collect([.human("what's on my screen?")])
        // Both capture tools, nothing else (take_window_screenshots arrived with the
        // per-window capture feature).
        #expect(
            await recorder.toolNameSets.first ?? []
                == ["take_screenshot", "take_window_screenshots"]
        )
    }

    @Test func dropsTextTools() async {
        let (agent, recorder) = recordingAgent()
        _ = await agent.collect([.human("hi")])
        let tools = await recorder.toolNameSets.first ?? []
        #expect(!tools.contains("write_todos"))
        #expect(!tools.contains("read_clipboard"))
        #expect(!tools.contains("write_clipboard"))
        #expect(!tools.contains("calculator"))
    }

    @Test func usesVisionPromptPlusScreenshotGuidance() async {
        let (agent, recorder) = recordingAgent()
        _ = await agent.collect([.human("hi")])
        let sys = await (recorder.systemPrompts.first ?? nil) ?? ""
        #expect(sys.contains(VisionPrompt.system))
        #expect(sys.contains(ScreenshotMiddleware.systemPrompt))
    }
}
