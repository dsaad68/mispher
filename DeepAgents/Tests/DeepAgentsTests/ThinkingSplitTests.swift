@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Testing

/// `ThinkingSplit` must move *every* `<think>…</think>` block into the reasoning
/// section — the agent's tool loop runs the model multiple times, so a reply can carry
/// several think blocks that must not leak into the answer body.
struct ThinkingSplitTests {
    @Test func plainTextIsAllAnswer() {
        let result = ThinkingSplit.split("Just an answer.")
        #expect(result.thinking == nil)
        #expect(result.answer == "Just an answer.")
    }

    @Test func singleBlockIsSplitOut() {
        let result = ThinkingSplit.split("<think>reasoning</think>The answer.")
        #expect(result.thinking == "reasoning")
        #expect(result.answer == "The answer.")
    }

    @Test func multipleBlocksAllBecomeReasoning() {
        let result = ThinkingSplit.split("<think>first</think><think>second</think> Final answer.")
        #expect(result.thinking == "first\n\nsecond")
        #expect(result.answer == "Final answer.")
        #expect(!result.answer.contains("<think>"))
        #expect(!result.answer.contains("</think>"))
    }

    @Test func textBetweenBlocksIsKeptInAnswer() {
        let result = ThinkingSplit.split("<think>a</think>middle<think>b</think>end")
        #expect(result.thinking == "a\n\nb")
        #expect(result.answer == "middleend")
    }

    @Test func unclosedTrailingBlockIsTreatedAsReasoning() {
        let result = ThinkingSplit.split("answer so far <think>still thinking")
        #expect(result.thinking == "still thinking")
        #expect(result.answer == "answer so far")
    }

    @Test func emptyThinkBlockYieldsNoReasoning() {
        let result = ThinkingSplit.split("<think></think>Answer.")
        #expect(result.thinking == nil)
        #expect(result.answer == "Answer.")
    }

    @Test func whitespaceOnlyThinkIsIgnored() {
        let result = ThinkingSplit.split("<think>   \n  </think>Hi.")
        #expect(result.thinking == nil)
        #expect(result.answer == "Hi.")
    }

    @Test func openingTagOnlyIsAllReasoning() {
        let result = ThinkingSplit.split("<think>working on it")
        #expect(result.thinking == "working on it")
        #expect(result.answer == "")
    }

    @Test func reasoningBeforeAnswerOnSamePass() {
        let result = ThinkingSplit.split("preamble <think>r</think> answer")
        #expect(result.thinking == "r")
        #expect(result.answer == "preamble  answer")
    }
}
