import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import Mispher
import Testing

/// `TranslationAgent` in isolation: a no-tool ReAct agent whose prompt is parameterized by
/// target language, plus pure `TranslationPrompt` interpolation checks. All with a scripted
/// `FakeChatModel`, no model download.
@Suite(.serialized)
struct TranslationAgentTests {
    @Test func composesNoToolsWithTargetPrompt() async {
        let recorder = RunRecorder()
        // Mirror what `TranslationAgent.make` composes (empty middleware, language-keyed
        // prompt), with a trailing recorder to capture the assembled request.
        let agent = createAgent(
            model: FakeChatModel(answer: "Bonjour", recorder: recorder),
            systemPrompt: TranslationPrompt.system(targetLanguage: "French"),
            middleware: []
        )
        _ = await agent.collect([.human("Hello")])
        #expect(await recorder.toolNameSets.first ?? [] == [])
        let sys = await (recorder.systemPrompts.first ?? nil) ?? ""
        #expect(sys.contains("into French"))
    }

    @Test func makeProducesAFinishingAgent() async {
        let agent = TranslationAgent.make(
            model: FakeChatModel(answer: "Hola"),
            instructions: TranslationPrompt.defaultInstructions, targetLanguage: "Spanish", text: "Hello"
        )
        let (ok, events) = await agent.collect([.human("Hello")])
        #expect(ok)
        #expect(events.didComplete)
        #expect(events.finalAnswer == "Hola")
    }

    @Test func promptInterpolatesLanguageAndInput() {
        let prompt = TranslationPrompt.system(
            instructions: TranslationPrompt.defaultInstructions, targetLanguage: "German", text: "Hello world"
        )
        #expect(prompt.contains("into German"))
        #expect(prompt.contains("Hello world"))
        #expect(!prompt.contains(TranslationPrompt.languageToken))
        #expect(!prompt.contains(TranslationPrompt.inputToken))
    }
}
