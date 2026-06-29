@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import MLXLMCommon
import Testing

/// Middleware composition: hook ordering and `ModelRequest.override` semantics.
struct MiddlewareTests {
    @Test func hooksRunInComposedOrder() async {
        let log = CallLog()
        let agent = createAgent(
            model: FakeChatModel(answer: "x"),
            middleware: [
                RecordingMiddleware(label: "A", log: log),
                RecordingMiddleware(label: "B", log: log)
            ]
        )
        _ = await agent.collect([.human("hi")])
        let entries = await log.entries
        #expect(
            entries == [
                "A.beforeAgent", "B.beforeAgent",
                "A.beforeModel", "B.beforeModel",
                "A.wrap.before", "B.wrap.before",
                "B.wrap.after", "A.wrap.after",
                "B.afterModel", "A.afterModel",
                "B.afterAgent", "A.afterAgent"
            ]
        )
    }

    @Test func wrapToolCallNestsFirstMiddlewareOutermost() async {
        let log = CallLog()
        let call = AgentToolCall(name: "echo", arguments: ["text": .string("y")])
        let agent = createAgent(
            model: FakeChatModel(answer: "x", toolCalls: [call]),
            tools: [EchoTool()],
            middleware: [
                RecordingMiddleware(label: "A", log: log),
                RecordingMiddleware(label: "B", log: log)
            ]
        )
        _ = await agent.collect([.human("hi")])
        let toolEntries = await log.entries.filter { $0.contains(".tool.") }
        #expect(toolEntries == ["A.tool.before", "B.tool.before", "B.tool.after", "A.tool.after"])
    }

    @Test func modelRequestOverrideReplacesSelectively() {
        let base = ModelRequest(messages: [.human("hi")], systemPrompt: "sys", tools: [EchoTool()])
        // Unchanged when omitted.
        #expect(base.override().systemPrompt == "sys")
        // Replaced when provided.
        #expect(base.override(systemPrompt: "new").systemPrompt == "new")
        // Cleared with an explicit nil.
        #expect(base.override(systemPrompt: .some(nil)).systemPrompt == nil)
        // Tools and messages override independently.
        #expect(base.override(tools: []).tools.isEmpty)
        #expect(base.override(messages: []).messages.isEmpty)
        #expect(base.override(tools: []).systemPrompt == "sys")
    }
}
