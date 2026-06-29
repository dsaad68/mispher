import DeepAgents
import Foundation
import MLXLMCommon

extension AgentMessage {
    /// Bridge an ``AgentMessage`` to `mlx-swift-lm`'s `Chat.Message` for chat templating.
    /// Image URLs are resolved to `UserInput.Image.url` here (the caller decides whether to
    /// include them based on the model's vision support). This is the MLX adapter's half of
    /// the message bridge — the framework's `AgentMessage` stays inference-agnostic.
    func toChatMessage(includeImages: Bool = true) -> Chat.Message {
        switch role {
        case .system: return .system(text)
        case .human:
            let images: [UserInput.Image] = includeImages ? imageURLs.map { .url($0) } : []
            return .user(text, images: images)
        case .ai: return .assistant(text)
        case .tool: return .tool(text)
        }
    }
}
