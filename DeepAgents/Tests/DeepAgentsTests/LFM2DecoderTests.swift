@testable import DeepAgents
@testable import DeepAgentsMLX
import Testing

/// The LFM2 decoder's streaming split: `<think>…</think>` is routed to the reasoning channel (even
/// when a tag straddles two chunks), tool-call spans are still stripped, and plain text carries no
/// reasoning.
struct LFM2DecoderTests {
    private func drive(_ tokens: [String]) -> (pieces: [AgentStreamChunk], message: AgentMessage) {
        let decoder = LFM2Decoder()
        var pieces: [AgentStreamChunk] = []
        for token in tokens { pieces += decoder.ingest(token) }
        let (trailing, message) = decoder.finish()
        pieces += trailing
        return (pieces, message)
    }

    private func reasoning(_ pieces: [AgentStreamChunk]) -> String {
        pieces.compactMap { if case .reasoning(let value) = $0 { value } else { nil } }.joined()
    }

    private func text(_ pieces: [AgentStreamChunk]) -> String {
        pieces.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined()
    }

    @Test func routesThinkSpanToReasoningAcrossChunkBoundaries() {
        // The `</think>` tag is deliberately split across two tokens.
        let (pieces, message) = drive(["<think>", "reason", "ing</thi", "nk>", "ans", "wer"])
        #expect(reasoning(pieces) == "reasoning")
        #expect(text(pieces) == "answer")
        #expect(message.reasoning == "reasoning")
        #expect(message.text == "answer")
    }

    @Test func plainTextCarriesNoReasoning() {
        let (pieces, message) = drive(["hello ", "world"])
        #expect(text(pieces) == "hello world")
        #expect(reasoning(pieces).isEmpty)
        #expect(message.reasoning == nil)
        #expect(message.text == "hello world")
    }

    @Test func toolCallSpanIsStrippedAlongsideReasoning() {
        let (pieces, message) = drive([
            "<think>plan</think>",
            "<|tool_call_start|>[echo(text=\"hi\")]<|tool_call_end|>"
        ])
        #expect(reasoning(pieces) == "plan")
        #expect(text(pieces).isEmpty) // the tool-call span is not visible text
        #expect(message.toolCalls.first?.name == "echo")
        #expect(message.reasoning == "plan")
    }

    @Test func unterminatedThinkIsAllReasoning() {
        let (pieces, message) = drive(["<think>still going"]) // no closing tag (truncated generation)
        #expect(reasoning(pieces) == "still going")
        #expect(text(pieces).isEmpty)
        #expect(message.reasoning == "still going")
        #expect(message.text.isEmpty)
    }

    @Test func emptyThinkYieldsNoReasoning() {
        let (_, message) = drive(["<think></think>answer"])
        #expect(message.reasoning == nil)
        #expect(message.text == "answer")
    }

    @Test func thinkInsideToolCallArgsStaysInTheToolSpan() {
        // The tool splitter runs first, so a `<think>` that lives inside tool-call arguments is
        // captured as part of the tool span - never mistaken for reasoning.
        let (pieces, message) = drive([
            "<|tool_call_start|>[echo(text=\"<think>x</think>\")]<|tool_call_end|>", "plain"
        ])
        #expect(reasoning(pieces).isEmpty)
        #expect(text(pieces) == "plain")
        #expect(message.reasoning == nil)
        #expect(message.toolCalls.first?.arguments["text"] == .string("<think>x</think>"))
    }

    @Test func trailingPartialTagIsEmittedLiterally() {
        // A stream ending mid-tag can't be a real `<think>`, so the held-back partial flushes as text.
        let (_, message) = drive(["answer<thi"])
        #expect(message.text == "answer<thi")
        #expect(message.reasoning == nil)
    }

    @Test func tagSplitCharByCharStillRoutesCorrectly() {
        let tokens = Array("<think>reason</think>a").map(String.init)
        let (pieces, message) = drive(tokens)
        #expect(reasoning(pieces) == "reason")
        #expect(text(pieces) == "a")
        #expect(message.reasoning == "reason")
        #expect(message.text == "a")
    }

    @Test func wrongCaseTagIsNotTreatedAsReasoning() {
        let (_, message) = drive(["<THINK>x</THINK>"]) // the tag is case-sensitive
        #expect(message.reasoning == nil)
        #expect(message.text == "<THINK>x</THINK>")
    }
}
