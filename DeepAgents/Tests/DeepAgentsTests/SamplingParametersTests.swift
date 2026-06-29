@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import MLXLMCommon
import Testing

/// Regression tests pinning each model family's sampling to Liquid's published
/// recommendations — drifting from them is exactly how tool calling degrades (the docs
/// recommend near-greedy decoding for tool use; the Thinking model additionally needs
/// `top_p 0.1` or its reasoning pass meanders into malformed calls).
struct SamplingParametersTests {
    private func model(_ id: String) -> MlxModel? {
        MlxModel.catalog.first { $0.id == id }
    }

    @Test func instructModelsUseLiquidRecommendedNearGreedySampling() throws {
        let instruct = try #require(model("LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16"))
        let parameters = instruct.agentParameters
        #expect(parameters.temperature == 0.1)
        #expect(parameters.topK == 50)
        #expect(parameters.repetitionPenalty == 1.05)
    }

    @Test func thinkingModelAddsTopP() throws {
        let thinking = try #require(model("LiquidAI/LFM2.5-1.2B-Thinking-MLX-bf16"))
        let parameters = thinking.agentParameters
        #expect(parameters.temperature == 0.1)
        #expect(parameters.topP == 0.1) // the Thinking-specific recommendation
        #expect(parameters.topK == 50)
        #expect(parameters.repetitionPenalty == 1.05)
        // Reasoning + tool loop need extra headroom over the instruct models.
        #expect(parameters.maxTokens == 8192)
    }

    @Test func moeModelUsesItsModelCardSettings() throws {
        let moe = try #require(model("LiquidAI/LFM2.5-8B-A1B-MLX-8bit"))
        let parameters = moe.agentParameters
        // The 8B-A1B model card recommends hotter sampling than the 1.2B family.
        #expect(parameters.temperature == 0.2)
        #expect(parameters.topK == 80)
        #expect(parameters.repetitionPenalty == 1.05)
    }

    @Test func visionModelsOmitRepetitionPenalty() throws {
        // Deliberate: the penalty ring buffer crashes on the VL processor's 2-D prompt
        // (see `MlxModel.agentParameters`); drop this expectation once upstream is fixed.
        let vision = try #require(model("mlx-community/LFM2.5-VL-1.6B-8bit"))
        #expect(vision.agentParameters.repetitionPenalty == nil)
    }
}
