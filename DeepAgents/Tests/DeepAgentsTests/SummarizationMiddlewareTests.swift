@testable import DeepAgents
import Foundation
import Testing

// Tests for the summarization / context-compaction middleware: the trigger threshold, the safe cut
// (never orphaning a tool result or splitting an AI/tool pair), the rewritten `[summary] + tail`
// shape, the rolling fold of a prior summary, and the archive offload of evicted originals.

/// Records the messages handed to it so a test can assert what was offloaded. An actor so it can
/// witness the `async` `CompactionArchive` requirement while holding mutable state.
private actor RecordingArchive: CompactionArchive {
    private(set) var calls: [[AgentMessage]] = []
    let returnsNil: Bool
    init(returnsNil: Bool = false) { self.returnsNil = returnsNil }
    func archive(_ messages: [AgentMessage], threadId: String) -> String? {
        calls.append(messages)
        // Number parts per call so a rolling test sees part-1, part-2, … in one `history/` directory.
        return returnsNil ? nil : "/tmp/history/part-\(calls.count).jsonl"
    }
}

/// A long-ish body so a handful of evicted messages clearly outweigh the compact summary that
/// replaces them (keeps `tokensAfter < tokensBefore` meaningful for the approximate counter).
private func body(_ label: String) -> String {
    label + ": " + String(repeating: "lorem ipsum dolor sit amet ", count: 8)
}

/// A 5-exchange history: h0 a1 h2 a3 h4 a5 h6 a7 h8 a9 (alternating human/ai), bodies long enough
/// to exceed a small window.
private func sampleHistory() -> [AgentMessage] {
    (0 ..< 10).map { i in i.isMultiple(of: 2) ? AgentMessage.human(body("user \(i)")) : .ai(body("assistant \(i)")) }
}

@Test func belowThresholdDoesNotCompact() async {
    // Default 32k window, a tiny history: nowhere near 85%, so an automatic pass is a no-op.
    let middleware = SummarizationMiddleware(model: FakeChatModel(answer: "S"))
    var messages = sampleHistory()
    let before = messages
    let outcome = await middleware.compact(&messages, threadId: nil, force: false)
    #expect(outcome == nil)
    #expect(messages.count == before.count)
}

@Test func aboveThresholdCompacts() async {
    // A small window forces the same tiny history over the 85% line.
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let middleware = SummarizationMiddleware(model: FakeChatModel(answer: "CONDENSED"), config: config)
    var messages = sampleHistory()
    let outcome = await middleware.compact(&messages, threadId: nil, force: false)
    #expect(outcome != nil)
    #expect(messages.first?.isSummary == true)
}

@Test func compactRewritesToSummaryPlusTail() async throws {
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let archive = RecordingArchive()
    let middleware = SummarizationMiddleware(
        model: FakeChatModel(answer: "CONDENSED"), archive: archive, config: config
    )
    var messages = sampleHistory()
    let tokensBefore = ApproximateTokenCounter().count(messages)
    let outcome = await middleware.compact(&messages, threadId: "thread-1", force: true)

    let result = try #require(outcome)
    // Shape: [summary .human] + [ack .ai] + tail, all roles valid for every backend.
    #expect(messages[0].role == .human)
    #expect(messages[0].isSummary)
    #expect(messages[0].source == AgentMessage.summarizationSource)
    #expect(messages[0].text.contains("CONDENSED"))
    #expect(messages[1].role == .ai)
    #expect(messages[1].isSummary)
    // The kept tail starts on a clean user-turn boundary (no orphan tool result, no leading ai).
    #expect(messages[2].role == .human)
    // The most recent turns are preserved verbatim.
    #expect(messages.last?.text == body("assistant 9"))
    // Compaction shrank the history, and reported the sizes + archive path.
    #expect(result.tokensBefore == tokensBefore)
    #expect(result.tokensAfter < result.tokensBefore)
    #expect(result.archivePath == "/tmp/history/part-1.jsonl") // outcome names this compaction's part
    #expect(messages[0].text.contains("/tmp/history")) // summary points at the history directory

    // The originals (not the synthetic summary/ack) were offloaded.
    let archived = await archive.calls
    #expect(archived.count == 1)
    #expect(archived[0].allSatisfy { !$0.isSummary })
    #expect(archived[0].count > 0)
}

@Test func cutNeverOrphansAToolResult() throws {
    // h0, a1(tool_call), t2(tool result), a3, h4, a5, h6 — a naive "keep last 3" would start the tail
    // at a tool/ai message; the safe cut moves it to the next user turn.
    let call = AgentToolCall(name: "echo", arguments: ["text": .string("hi")])
    let messages: [AgentMessage] = [
        .human("q0"),
        .ai("", toolCalls: [call]),
        .tool("result", toolCallID: call.id),
        .ai("a3"),
        .human("q4"),
        .ai("a5"),
        .human("q6")
    ]
    let cut = try #require(SummarizationMiddleware.safeCutIndex(messages, keepRecent: 3))
    #expect(messages[cut].role == .human) // tail starts on a user turn
    #expect(cut >= 1)
}

@Test func noHumanBoundaryYieldsNoCut() {
    // Only the very first message is a user turn; there's no later boundary to keep a valid tail at.
    let call = AgentToolCall(name: "echo", arguments: [:])
    let messages: [AgentMessage] = [
        .human("q0"),
        .ai("", toolCalls: [call]),
        .tool("r", toolCallID: call.id),
        .ai("a3")
    ]
    #expect(SummarizationMiddleware.safeCutIndex(messages, keepRecent: 2) == nil)
}

@Test func emptySummaryAbortsCompaction() async {
    // If the model returns nothing usable, the history is left untouched rather than wiped.
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let middleware = SummarizationMiddleware(model: FakeChatModel(answer: ""), config: config)
    var messages = sampleHistory()
    let before = messages
    let outcome = await middleware.compact(&messages, threadId: nil, force: true)
    #expect(outcome == nil)
    #expect(messages.count == before.count)
}

@Test func rollingCompactionFoldsPriorSummary() async {
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let middleware = SummarizationMiddleware(model: FakeChatModel(answer: "CONDENSED"), config: config)
    var messages = sampleHistory()

    let first = await middleware.compact(&messages, threadId: "t", force: true)
    #expect(first != nil)
    // Grow the conversation, then compact again.
    messages += (10 ..< 18).map { i in
        i.isMultiple(of: 2) ? AgentMessage.human(body("user \(i)")) : .ai(body("assistant \(i)"))
    }
    let second = await middleware.compact(&messages, threadId: "t", force: true)
    #expect(second != nil)

    // Still exactly one leading summary turn (the prior one was folded, not stacked) + its ack.
    #expect(messages[0].isSummary)
    #expect(messages[0].role == .human)
    #expect(messages[1].isSummary)
    let leadingSummaries = messages.prefix { $0.isSummary }
    #expect(leadingSummaries.count == 2) // summary + ack only
    #expect(messages.dropFirst(2).allSatisfy { !$0.isSummary })
}

// MARK: - Run-level plumbing (automatic path) and the manual compact entry point

/// An in-memory checkpointer that is ALSO a ``CompactionArchive``, so a run-level test can assert
/// both the persisted history and the offload in one double (the real hosts conform their store to
/// both the same way).
private actor RecordingMemory: AgentCheckpointer, CompactionArchive {
    private var threads: [String: [AgentMessage]] = [:]
    private(set) var archived: [[AgentMessage]] = []
    func load(_ threadId: String) -> [AgentMessage] { threads[threadId] ?? [] }
    func save(_ threadId: String, _ messages: [AgentMessage]) { threads[threadId] = messages }
    func archive(_ messages: [AgentMessage], threadId: String) -> String? {
        archived.append(messages)
        return "/tmp/\(threadId)/history/part-\(archived.count).jsonl"
    }
}

@Test func autoCompactionPersistsHistoryAndEmitsEvent() async {
    // A small window so the seeded history is already over 85% when the run begins: the automatic
    // beforeModel pass must compact, emit .contextCompacted, offload, and persist [summary, ack] + tail.
    let memory = RecordingMemory()
    await memory.save("t", sampleHistory())
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let agent = createAgent(
        model: FakeChatModel(answer: "DONE"),
        middleware: [SummarizationMiddleware(
            model: FakeChatModel(answer: "CONDENSED"), archive: memory, config: config
        )],
        memory: memory
    )

    let (ok, events) = await agent.collect([.human("carry on")], threadId: "t")
    #expect(ok)
    let compactions = events.compactMap { event -> (Int, Int)? in
        if case .contextCompacted(let before, let after) = event { return (before, after) } else { return nil }
    }
    #expect(compactions.count == 1) // fired once, not re-fired after it dropped below threshold
    #expect(compactions.first.map { $0.1 < $0.0 } == true) // after < before

    // The persisted history was rewritten to [summary, ack] + tail (+ this run's final answer).
    let saved = await memory.load("t")
    #expect(saved.first?.isSummary == true)
    #expect(saved.first?.role == .human)
    #expect(saved.dropFirst().first?.isSummary == true)
    #expect(saved.dropFirst().first?.role == .ai)
    #expect(saved.last?.text == "DONE")
    // The evicted originals were offloaded exactly once, and only true originals.
    let archived = await memory.archived
    #expect(archived.count == 1)
    #expect(archived[0].allSatisfy { !$0.isSummary })
}

@Test func manualCompactRoundTripsThroughMemory() async throws {
    let memory = InMemoryCheckpointer()
    await memory.save("t", sampleHistory())
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let agent = createAgent(
        model: FakeChatModel(answer: "X"),
        middleware: [SummarizationMiddleware(model: FakeChatModel(answer: "CONDENSED"), config: config)],
        memory: memory
    )
    let outcome = try #require(await agent.compact(threadId: "t"))
    // What the manual compact persisted is exactly what its outcome reported.
    let saved = await memory.load("t")
    #expect(saved.count == outcome.messages.count)
    #expect(saved.map(\.role) == outcome.messages.map(\.role))
    #expect(zip(saved, outcome.messages).allSatisfy { $0.isSummary == $1.isSummary && $0.text == $1.text })
    #expect(saved.first?.isSummary == true)
}

@Test func manualCompactReturnsNilWithoutMiddlewareOrThread() async {
    let memory = InMemoryCheckpointer()
    await memory.save("t", sampleHistory())
    // No summarization middleware registered -> nil (nothing to do).
    let bare = createAgent(model: FakeChatModel(answer: "X"), memory: memory)
    #expect(await bare.compact(threadId: "t") == nil)
    // Middleware present but no thread id -> nil (nothing to load or save against).
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let agent = createAgent(
        model: FakeChatModel(answer: "X"),
        middleware: [SummarizationMiddleware(model: FakeChatModel(answer: "C"), config: config)],
        memory: memory
    )
    #expect(await agent.compact(threadId: nil) == nil)
}

// MARK: - Atomicity: a rejected compaction writes no orphan archive part

@Test func compactionAbortsWhenSummaryDoesNotShrink() async {
    // A summarizer that returns more text than it replaces: the shrink guard must refuse the rewrite
    // (otherwise the automatic path would re-summarize every round) AND must not have written a part.
    let huge = String(repeating: "verbose ", count: 400)
    let archive = RecordingArchive()
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let middleware = SummarizationMiddleware(model: FakeChatModel(answer: huge), archive: archive, config: config)
    var messages = sampleHistory()
    let before = messages
    let outcome = await middleware.compact(&messages, threadId: "t", force: true)
    #expect(outcome == nil)
    #expect(messages.count == before.count) // history left untouched
    #expect(messages.first?.isSummary != true)
    #expect(await archive.calls.isEmpty) // no orphan history part for a rejected compaction
}

@Test func emptySummaryWritesNoArchivePart() async {
    // The ordering fix: archival happens only after a usable summary, so an empty summary leaves no
    // orphan part behind.
    let archive = RecordingArchive()
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let middleware = SummarizationMiddleware(model: FakeChatModel(answer: ""), archive: archive, config: config)
    var messages = sampleHistory()
    _ = await middleware.compact(&messages, threadId: "t", force: true)
    #expect(await archive.calls.isEmpty)
}

@Test func compactionWithoutArchiveOmitsTheSavedToPointer() async throws {
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let middleware = SummarizationMiddleware(model: FakeChatModel(answer: "CONDENSED"), config: config)
    var messages = sampleHistory()
    let outcome = try #require(await middleware.compact(&messages, threadId: nil, force: true))
    #expect(outcome.archivePath == nil)
    #expect(!messages[0].text.contains("saved to")) // no dangling "saved to <path>" clause
    #expect(messages[0].text.contains("CONDENSED"))
}

// MARK: - Cut selection and budgeting

@Test func safeCutIndexFallsBackToEarlierHumanBoundary() throws {
    // The recent tail is all assistant/tool (a long single-turn tool chain), so there's no human at
    // or after the target; the cut must fall back to the earlier human boundary, and never to index 0.
    let call = AgentToolCall(name: "echo", arguments: [:])
    let messages: [AgentMessage] = [
        .human("q0"), .human("q1"),
        .ai("", toolCalls: [call]), .tool("r", toolCallID: call.id),
        .ai("a"), .ai("b")
    ]
    let cut = try #require(SummarizationMiddleware.safeCutIndex(messages, keepRecent: 2))
    #expect(cut == 1) // backward branch: the earlier human, not index 0
    #expect(messages[cut].role == .human)
}

@Test func clampToBudgetNeverExceedsMaxChars() {
    let text = String(repeating: "abcde ", count: 2000) // 12000 chars, well over any budget below
    for maxChars in [600, 1000, 4096, 8000] {
        let clamped = SummarizationMiddleware.clampToBudget(text, maxChars: maxChars)
        #expect(clamped.count <= maxChars) // a hard cap, marker included
        #expect(clamped.contains("omitted to fit the summarizer")) // the elision was noted
    }
    #expect(SummarizationMiddleware.clampToBudget("short", maxChars: 4096) == "short") // under budget: verbatim
}

// MARK: - Prompt-overhead accounting (system prompt + tool schemas count toward the trigger)

@Test func triggerAccountsForPromptOverhead() async throws {
    let config = SummarizationConfig(fallbackContextWindow: 1000, keepRecentMessages: 3)
    let middleware = SummarizationMiddleware(model: FakeChatModel(answer: "CONDENSED"), config: config)
    // sampleHistory is ~560 tokens: under the 850-token (85% of 1000) threshold on its own.
    var withoutOverhead = sampleHistory()
    #expect(await middleware.compact(&withoutOverhead, threadId: nil, force: false, overheadTokens: 0) == nil)
    // A large system-prompt + tool-schema overhead pushes the same history over the line.
    var withOverhead = sampleHistory()
    let outcome = try #require(
        await middleware.compact(&withOverhead, threadId: nil, force: false, overheadTokens: 500)
    )
    #expect(outcome.tokensBefore > 850) // the reported total includes the overhead
    #expect(withOverhead.first?.isSummary == true)
}

@Test func promptOverheadTextIncludesSystemPromptAndToolSchemas() {
    let text = SummarizationMiddleware.promptOverheadText(
        systemPrompt: "You are a helpful agent.", tools: [EchoTool()]
    )
    #expect(text.contains("You are a helpful agent.")) // system prompt counts
    #expect(text.contains("echo")) // tool name
    #expect(text.contains("Echo the given text.")) // tool description
    #expect(text.contains("Text to echo.")) // parameter description
    // Nothing to add when there's no system prompt and no tools.
    #expect(SummarizationMiddleware.promptOverheadText(systemPrompt: nil, tools: []).isEmpty)
}

// MARK: - Rolling archive reference + token-bounded tail

@Test func rollingCompactionSummaryReferencesHistoryDirectory() async {
    let config = SummarizationConfig(fallbackContextWindow: 60, keepRecentMessages: 3)
    let archive = RecordingArchive()
    let middleware = SummarizationMiddleware(
        model: FakeChatModel(answer: "CONDENSED"), archive: archive, config: config
    )
    var messages = sampleHistory()
    _ = await middleware.compact(&messages, threadId: "t", force: true)
    messages += (10 ..< 18).map { i in
        i.isMultiple(of: 2) ? AgentMessage.human(body("user \(i)")) : .ai(body("assistant \(i)"))
    }
    let second = await middleware.compact(&messages, threadId: "t", force: true)

    #expect(await archive.calls.count == 2) // two parts were written
    #expect(second?.archivePath == "/tmp/history/part-2.jsonl") // outcome still names this part
    // The live summary points at the directory (covers part-1 AND part-2), not just the newest part.
    #expect(messages[0].text.contains("/tmp/history"))
    #expect(!messages[0].text.contains("part-2.jsonl"))
}

@Test func tailIsBoundedByTokensNotJustMessageCount() async throws {
    // keepRecentMessages would keep 5, but the token budget caps the tail far below that when the
    // recent messages are large.
    let big = String(repeating: "data ", count: 200) // ~1000 chars ~250 tokens each
    let history: [AgentMessage] = (0 ..< 8).map { i in
        i.isMultiple(of: 2) ? AgentMessage.human("\(big) \(i)") : .ai("\(big) \(i)")
    }
    // window 2000 -> keepRecentTokens = 0.25 * 2000 = 500 -> only ~2 of these ~250-token messages fit.
    let config = SummarizationConfig(fallbackContextWindow: 2000, keepRecentMessages: 5)
    let middleware = SummarizationMiddleware(model: FakeChatModel(answer: "S"), config: config)
    var messages = history
    let outcome = try #require(await middleware.compact(&messages, threadId: nil, force: true))
    let tail = messages.dropFirst(2) // everything after [summary, ack]
    #expect(tail.count <= 3) // token budget capped the tail below keepRecentMessages (5)
    #expect(outcome.tokensAfter < outcome.tokensBefore)
}
