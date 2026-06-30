import DeepAgents
import Foundation

/// Builds the zero-tool ReAct agent for Rewrite Mode (edit highlighted text by voice).
/// Mirrors ``TranslationAgent`` / ``CleanupAgent``: one model round, no tools. The selected
/// text is baked into the system prompt; the spoken instruction is the human turn.
enum RewriteAgent {
    static func make(
        model: any ChatModel,
        selection: String,
        instructions: String,
        messageLog: (any AgentMessageLog)? = nil
    ) -> ReactAgent {
        createAgent(
            model: model,
            systemPrompt: RewritePrompt.system(instructions: instructions, selection: selection),
            middleware: [],
            messageLog: messageLog
        )
    }
}
