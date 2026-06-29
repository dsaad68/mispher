@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// Message bridging to `mlx-swift-lm`'s `Chat.Message`, tool-call mapping, and the
/// generated tool schema (`ToolSchema`).
struct AgentMessageTests {
    @Test func bridgesRolesToChatMessages() {
        #expect(AgentMessage.system("s").toChatMessage().role == .system)
        #expect(AgentMessage.human("h").toChatMessage().role == .user)
        #expect(AgentMessage.ai("a").toChatMessage().role == .assistant)
        #expect(AgentMessage.tool("t").toChatMessage().role == .tool)
        #expect(AgentMessage.human("hello").toChatMessage().content == "hello")
    }

    @Test func toolMessageCarriesToolCallID() {
        let id = UUID()
        let message = AgentMessage.tool("result", toolCallID: id)
        #expect(message.role == .tool)
        #expect(message.toolCallID == id)
        #expect(message.toChatMessage().role == .tool)
        #expect(message.toChatMessage().content == "result")
        // Non-tool turns, and tool turns built without one, have no tool_call_id.
        #expect(AgentMessage.ai("a").toolCallID == nil)
        #expect(AgentMessage.tool("x").toolCallID == nil)
    }

    @Test func humanImagesIncludedOnlyWhenRequested() {
        let url = URL(fileURLWithPath: "/tmp/x.png")
        let message = AgentMessage.human("look", imageURLs: [url])
        #expect(message.toChatMessage(includeImages: true).images.count == 1)
        #expect(message.toChatMessage(includeImages: false).images.isEmpty)
    }

    @Test func mapsUnderlyingToolCall() {
        let toolCall = ToolCall(function: .init(name: "echo", arguments: ["text": .string("hi")]))
        let mapped = AgentToolCall(toolCall)
        #expect(mapped.name == "echo")
        if case .string(let text)? = mapped.arguments["text"] {
            #expect(text == "hi")
        } else {
            Issue.record("expected a string argument named text")
        }
    }

    @Test func toolSpecHasExpectedShape() {
        let spec = EchoTool().toolSchema()
        #expect(spec["type"] as? String == "function")
        let function = spec["function"] as? [String: any Sendable]
        #expect(function?["name"] as? String == "echo")
        let parameters = function?["parameters"] as? [String: any Sendable]
        #expect(parameters?["required"] as? [String] == ["text"])
    }
}
