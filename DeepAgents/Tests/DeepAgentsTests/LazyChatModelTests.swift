@testable import DeepAgents
import Testing

/// ``LazyChatModel`` resolves the underlying model lazily and pairs every successful `begin()` with
/// exactly one `end()` - on success, on a thrown turn, and on cancellation-after-begin (which surfaces
/// as a thrown turn) - while a `begin()` that itself fails gets no `end()` (its owner undoes its own
/// active-use claim in that path). An imbalance here would leak an idle pin or unload a live model.
struct LazyChatModelTests {
    private actor CallCounter {
        private(set) var begins = 0
        private(set) var ends = 0
        func begin() { begins += 1 }
        func end() { ends += 1 }
    }

    private enum StubError: Error { case turnFailed, beginFailed }

    /// A model whose single round always throws, standing in for a failed / cancelled generation.
    private struct ThrowingChatModel: ChatModel {
        let supportsVision = false
        let modelID: String? = nil
        let contextWindowTokens: Int? = nil
        func makeSession() -> any ModelTurnSession { ThrowingSession() }
    }

    private final class ThrowingSession: ModelTurnSession {
        func nextTurn(
            messages: [AgentMessage], systemPrompt: String?, tools: [any AgentTool],
            onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
        ) async throws -> AgentMessage {
            throw StubError.turnFailed
        }
    }

    private func lazyModel(
        _ counter: CallCounter, resolve: @escaping @Sendable () async throws -> any ChatModel
    ) -> LazyChatModel {
        LazyChatModel(
            supportsVision: true, modelID: "vendor/vlm", contextWindowTokens: 4096,
            begin: { await counter.begin(); return try await resolve() },
            end: { await counter.end() }
        )
    }

    @Test("Static metadata is reported without resolving (no begin) the underlying model")
    func metadataWithoutLoading() async {
        let counter = CallCounter()
        let model = lazyModel(counter) { FakeChatModel(answer: "hi") }
        #expect(model.supportsVision)
        #expect(model.modelID == "vendor/vlm")
        #expect(model.contextWindowTokens == 4096)
        #expect(await counter.begins == 0) // image gating + the context meter never trigger a load
    }

    @Test("A successful turn pairs begin with exactly one end")
    func endOnceOnSuccess() async throws {
        let counter = CallCounter()
        let model = lazyModel(counter) { FakeChatModel(answer: "hi") }
        _ = try await model.makeSession().nextTurn(
            messages: [], systemPrompt: nil, tools: [], onChunk: { _ in }
        )
        #expect(await counter.begins == 1)
        #expect(await counter.ends == 1)
    }

    @Test("A thrown turn still releases the model (end called once)")
    func endOnceWhenTurnThrows() async {
        let counter = CallCounter()
        let model = lazyModel(counter) { ThrowingChatModel() }
        await #expect(throws: StubError.self) {
            _ = try await model.makeSession().nextTurn(
                messages: [], systemPrompt: nil, tools: [], onChunk: { _ in }
            )
        }
        #expect(await counter.begins == 1)
        #expect(await counter.ends == 1)
    }

    @Test("A begin that fails gets no end (the owner undoes its own claim there)")
    func endSkippedWhenBeginFails() async {
        let counter = CallCounter()
        let model = lazyModel(counter) { throw StubError.beginFailed }
        await #expect(throws: StubError.self) {
            _ = try await model.makeSession().nextTurn(
                messages: [], systemPrompt: nil, tools: [], onChunk: { _ in }
            )
        }
        #expect(await counter.begins == 1)
        #expect(await counter.ends == 0)
    }
}
