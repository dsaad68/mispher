import DeepAgents
import Foundation

/// Builds the zero-tool ReAct agent that runs the on-device dictation cleanup pass (T3).
/// Mirrors ``TranslationAgent`` / ``RewriteAgent``: one model round, no tools. The transcript is
/// baked into the system prompt; a fixed neutral user turn (``CleanupPrompt/userDirective``) drives
/// the run, so the transcript is never treated as a request to answer.
enum CleanupAgent {
    static func make(
        model: any ChatModel,
        instructions: String,
        text: String,
        messageLog: (any AgentMessageLog)? = nil
    ) -> ReactAgent {
        createAgent(
            model: model,
            systemPrompt: CleanupPrompt.system(instructions: instructions, text: text),
            middleware: [],
            messageLog: messageLog
        )
    }
}
