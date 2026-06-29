import DeepAgents
import Foundation
import MLX
import MLXLMCommon

/// A `ChatModel` over an in-process `mlx-swift-lm` `ModelContainer`.
///
/// Each run gets one `RebuildTurnSession`. The model node is **single-shot and stateless**:
/// `ReactAgent` drives the ReAct loop and, each round, hands the session the full
/// conversation; the session rebuilds the prompt from those messages, generates one pass
/// from a fresh cache, and surfaces any tool calls to the agent (it does not dispatch
/// them). Because the prompt is rebuilt from structured messages every round — rather than
/// continued on a live KV cache — the chat template renders the exchange faithfully
/// (assistant tool calls and tool results included) and automatically drops the model's
/// own historical `<think>` blocks, and middleware is free to rewrite history between
/// rounds.
public struct MlxChatModel: ChatModel {
    let container: ModelContainer
    public let supportsVision: Bool
    /// Hugging Face repo id of the loaded model, recorded on each logged message so a
    /// transcript says which model produced it. `nil` only in tests/previews.
    public var modelID: String?
    /// The model's context window in tokens (from ``MlxModel/contextWindowTokens``), so
    /// summarization's 85% trigger and the context meter measure against the real budget.
    public var contextWindowTokens: Int?
    // Conservative default: Liquid's recommended sampling for the LFM2.5 1.2B instruct
    // models (temperature 0.1, top-k 50, repetition penalty 1.05) for reliable tool use.
    // Production call sites override this with the per-model `MlxModel.agentParameters`
    // (e.g. 8B-A1B wants 0.2 / top-k 80, Thinking adds top-p 0.1). Generous token budget
    // because reasoning models emit long `<think>` blocks and the tool loop re-generates
    // per round, so a small cap truncates the final answer.
    var generateParameters: GenerateParameters = .init(
        maxTokens: 4096, temperature: 0.1, topK: 50, repetitionPenalty: 1.05
    )

    public init(
        container: ModelContainer,
        supportsVision: Bool,
        modelID: String? = nil,
        contextWindowTokens: Int? = nil,
        generateParameters: GenerateParameters
    ) {
        self.container = container
        self.supportsVision = supportsVision
        self.modelID = modelID
        self.contextWindowTokens = contextWindowTokens
        self.generateParameters = generateParameters
    }

    public func makeSession() -> any ModelTurnSession {
        RebuildTurnSession(
            container: container,
            supportsVision: supportsVision,
            generateParameters: generateParameters
        )
    }
}

/// One run's stateless model node: each `nextTurn` rebuilds the prompt from the supplied
/// messages and generates one pass against a fresh cache.
///
/// A reference type only to satisfy `ModelTurnSession: AnyObject`; it holds no per-round
/// state, so it is safe to reuse across rounds (and would be safe to share, though
/// `ReactAgent` uses it from one task).
public final class RebuildTurnSession: ModelTurnSession {
    private let container: ModelContainer
    private let supportsVision: Bool
    private let generateParameters: GenerateParameters
    private let codec = LFM2MessageCodec()

    public init(
        container: ModelContainer, supportsVision: Bool, generateParameters: GenerateParameters
    ) {
        self.container = container
        self.supportsVision = supportsVision
        self.generateParameters = generateParameters
    }

    public func nextTurn(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [any AgentTool],
        onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
    ) async throws -> AgentMessage {
        // Encode the canonical history to the LFM2 wire shape; the codec owns all format quirks.
        let request = codec.encode(
            messages, systemPrompt: systemPrompt, tools: tools, supportsVision: supportsVision
        )
        let supportsVision = supportsVision
        let parameters = generateParameters
        let codec = codec

        // Generate inside the container's lock; resolve image URLs to `UserInput.Image`
        // here (off the message-building path, which stays `Sendable`). We suppress
        // mlx-swift-lm's built-in tool-call parsing (its Pythonic parser truncates
        // list/dict arguments at the first comma) by running with a non-matching
        // `toolCallFormat`, so the raw `<|tool_call_start|>…<|tool_call_end|>` text reaches the
        // codec's decoder, which strips those spans and parses the calls itself.
        return try await container.perform { context in
            let images: [UserInput.Image] = supportsVision ? request.imageURLs.map { .url($0) } : []
            let userInput = UserInput(
                messages: request.messages, images: images,
                tools: request.toolSpecs.isEmpty ? nil : request.toolSpecs
            )
            let lmInput = try await context.processor.prepare(input: userInput)

            var configuration = context.configuration
            configuration.toolCallFormat = .json // ≠ LFM2's tags → built-in parser stands down

            let iterator = try TokenIterator(
                input: lmInput, model: context.model, cache: nil, parameters: parameters
            )
            let (stream, task) = generateTask(
                promptTokenCount: lmInput.text.tokens.size,
                modelConfiguration: configuration,
                tokenizer: context.tokenizer,
                iterator: iterator
            )

            let decoder = codec.makeDecoder()
            for await generation in stream {
                guard case .chunk(let chunk) = generation else { continue }
                for piece in decoder.ingest(chunk) { onChunk(piece) }
            }
            let (trailing, message) = decoder.finish()
            for piece in trailing { onChunk(piece) }
            await task.value
            return message
        }
    }
}
