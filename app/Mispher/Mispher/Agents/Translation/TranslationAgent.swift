import DeepAgents
import Foundation

/// The on-device translation agent: a ReAct agent with **no tools**, so its single model
/// round produces the translation directly. The system prompt is parameterized by target
/// language (``TranslationPrompt``), so it has a bespoke `make` rather than conforming to
/// ``AgentDefinition`` (whose `systemPrompt` is a fixed constant).
///
/// Translation is one-shot: no memory, no tools. The caller drives the run and reads the
/// final answer off the event stream (e.g. via `AgentTimelineBuilder`).
enum TranslationAgent {
    static func make(
        model: any ChatModel,
        instructions: String,
        targetLanguage: String,
        text: String,
        messageLog: (any AgentMessageLog)? = nil
    ) -> ReactAgent {
        createAgent(
            model: model,
            systemPrompt: TranslationPrompt.system(instructions: instructions, targetLanguage: targetLanguage, text: text),
            middleware: [],
            messageLog: messageLog
        )
    }
}
