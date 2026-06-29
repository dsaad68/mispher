@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Testing

/// Short-term memory: the in-memory checkpointer and thread-scoped persistence across
/// agent invocations.
struct MemoryTests {
    @Test func checkpointerSavesLoadsAndClears() async {
        let memory = InMemoryCheckpointer()
        #expect(await memory.load("t").isEmpty)

        await memory.save("t", [.human("hi"), .ai("yo")])
        #expect(await memory.load("t").count == 2)

        await memory.clear("t")
        #expect(await memory.load("t").isEmpty)
    }

    @Test func threadMemoryPersistsAcrossRuns() async {
        let memory = InMemoryCheckpointer()
        let recorder = RunRecorder()
        let agent = createAgent(
            model: FakeChatModel(answer: "reply"),
            middleware: [RequestRecordingMiddleware(recorder: recorder)],
            memory: memory
        )

        _ = await agent.collect([.human("first")], threadId: "chat")
        _ = await agent.collect([.human("second")], threadId: "chat")

        let saved = await memory.load("chat")
        #expect(saved.map(\.role) == [.human, .ai, .human, .ai])
        #expect(saved[0].text == "first")
        #expect(saved[2].text == "second")

        // On the second run the assembled request had the prior 2 turns plus the new one.
        #expect(await recorder.messageCounts == [1, 3])
    }

    @Test func noThreadIdMeansNoPersistence() async {
        let memory = InMemoryCheckpointer()
        let agent = createAgent(model: FakeChatModel(answer: "x"), memory: memory)
        _ = await agent.collect([.human("hi")]) // no threadId
        #expect(await memory.load("anything").isEmpty)
    }
}
