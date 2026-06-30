import DeepAgents
import DeepAgentsMacTools
import Foundation

/// The screen-aware agent. At the moment it carries only the screenshot capability
/// (`take_screenshot`) — intentionally narrower than the general ``AskAgent``, which also
/// gets the todo/clipboard/utility tools. Used for vision models (VLMs) in both the
/// main-view Ask flow and the Settings chat.
enum VisionAgent: AgentDefinition {
    static var systemPrompt: String { VisionPrompt.system }

    static func middleware() -> [any AgentMiddleware] {
        [ScreenshotMiddleware()]
    }
}
