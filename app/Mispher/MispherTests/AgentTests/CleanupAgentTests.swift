import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import Mispher
import Testing

/// `CleanupAgent` in isolation: a no-tool ReAct agent whose system prompt bakes in the transcript,
/// plus pure `CleanupPrompt` interpolation checks. All with a scripted `FakeChatModel`, no model
/// download. Mirrors ``TranslationAgentTests``.
@Suite(.serialized)
struct CleanupAgentTests {
    @Test func composesNoToolsWithCleanupPrompt() async {
        let recorder = RunRecorder()
        // Mirror what `CleanupAgent.make` composes (empty middleware, transcript baked into the
        // system prompt), with a trailing recorder to capture the assembled request.
        let agent = createAgent(
            model: FakeChatModel(answer: "Hello.", recorder: recorder),
            systemPrompt: CleanupPrompt.system(instructions: CleanupPrompt.defaultInstructions, text: "hello"),
            middleware: []
        )
        _ = await agent.collect([.human(CleanupPrompt.userDirective)])
        #expect(await recorder.toolNameSets.first ?? [] == [])
        let sys = await (recorder.systemPrompts.first ?? nil) ?? ""
        #expect(sys.contains("never answer questions"))
        #expect(sys.contains("hello"))
    }

    @Test func makeProducesAFinishingAgent() async {
        let agent = CleanupAgent.make(
            model: FakeChatModel(answer: "Hello."),
            instructions: CleanupPrompt.defaultInstructions, text: "hello"
        )
        let (ok, events) = await agent.collect([.human(CleanupPrompt.userDirective)])
        #expect(ok)
        #expect(events.didComplete)
        #expect(events.finalAnswer == "Hello.")
    }

    @Test func promptInterpolatesInput() {
        let prompt = CleanupPrompt.system(
            instructions: CleanupPrompt.defaultInstructions, text: "hello world"
        )
        #expect(prompt.contains("hello world"))
        #expect(!prompt.contains(CleanupPrompt.inputToken))
    }

    @Test func blankInstructionsFallBackToDefault() {
        let blank = CleanupPrompt.system(instructions: "   \n  ", text: "hello world")
        let def = CleanupPrompt.system(instructions: CleanupPrompt.defaultInstructions, text: "hello world")
        #expect(blank == def)
    }

    @Test func missingTokenAppendsTranscript() {
        // A custom prompt that dropped the {{INPUT}} pill must still receive the transcript, so the
        // input can never be stranded.
        let prompt = CleanupPrompt.system(instructions: "Just fix the punctuation.", text: "hello world")
        #expect(prompt.contains("Just fix the punctuation."))
        #expect(prompt.contains("hello world"))
        #expect(!prompt.contains(CleanupPrompt.inputToken))
    }
}
