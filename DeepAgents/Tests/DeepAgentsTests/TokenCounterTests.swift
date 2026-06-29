@testable import DeepAgents
import Foundation
import Testing

// Tests for the approximate token counter that drives the 85% compaction trigger and the context
// meter: the chars-per-token rounding, and which parts of a message contribute to the estimate
// (visible text + tool calls, but not reasoning or images).

@Test func approximateCounterCeilsCharactersPerToken() {
    let counter = ApproximateTokenCounter() // 4 chars per token
    #expect(counter.count("") == 0)
    #expect(counter.count("a") == 1) // ceil(1/4)
    #expect(counter.count("abcd") == 1)
    #expect(counter.count("abcde") == 2) // ceil(5/4)
    #expect(counter.count("12345678") == 2)
    // A zero/negative divisor is clamped to 1 char per token rather than trapping.
    #expect(ApproximateTokenCounter(charactersPerToken: 0).count("abcd") == 4)
}

@Test func messageTokenizableTextIncludesToolCallsExcludesReasoning() {
    let call = AgentToolCall(name: "search", arguments: ["q": .string("readme")])
    let ai = AgentMessage.ai(
        "answer text", toolCalls: [call],
        reasoning: "a long private chain of thought that must not be counted"
    )
    let text = tokenizableText(of: ai)
    #expect(text.contains("answer text")) // visible answer counts
    #expect(text.contains("search")) // tool name counts
    #expect(text.contains("q: readme")) // rendered tool arguments count
    #expect(!text.contains("private chain")) // reasoning is dropped on replay, so it isn't counted
}

@Test func messageListCountSumsPerMessageTokenizableText() {
    let counter = ApproximateTokenCounter()
    let messages: [AgentMessage] = [.human("hello there"), .ai("general kenobi")]
    let expected = messages.reduce(0) { $0 + counter.count(tokenizableText(of: $1)) }
    #expect(counter.count(messages) == expected)
}
