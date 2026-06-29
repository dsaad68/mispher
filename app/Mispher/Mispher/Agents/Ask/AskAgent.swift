import DeepAgents
import DeepAgentsMacTools
import Foundation

/// The general on-device text-assistant agent: planning, clipboard, datetime, and
/// calculator tools. Used single-turn by the main-view Ask flow and multi-turn (with
/// memory) by the Settings chat — both via the defaulted ``AgentDefinition/make(model:memory:messageLog:)``.
enum AskAgent: AgentDefinition {
    static var systemPrompt: String { AskPrompt.system }

    static func middleware() -> [any AgentMiddleware] {
        [TodoListMiddleware(), ClipboardMiddleware(), UtilityMiddleware()]
    }
}
