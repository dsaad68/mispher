@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// The JSONL message log: `<think>` reasoning split from the answer content for assistant turns, and
/// `task` delegations distinguished from ordinary tool calls (the subagent named on both the call
/// and its result line). Writes to a temp dir and reads the file back.
struct AgentMessageLogTests {
    @Test func splitsReasoningAndDistinguishesTaskFromTool() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-log-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = JSONLMessageLog(directory: dir)

        let taskCall = AgentToolCall(
            name: "task",
            arguments: ["description": .string("look"), "subagent_type": .string("vision")]
        )
        await log.append(
            .ai("<think>I should look</think>Delegating.", toolCalls: [taskCall]), threadId: nil
        )
        await log.append(.tool("I see an error.", toolCallID: taskCall.id), threadId: nil)

        let echoCall = AgentToolCall(name: "echo", arguments: ["text": .string("hi")])
        await log.append(
            .ai("", toolCalls: [echoCall]), threadId: nil,
            context: AgentLogContext(
                modelID: "LiquidAI/LFM2.5-8B-A1B-MLX-8bit", round: 2, generationSeconds: 1.23456
            )
        )
        await log.append(.tool("hi", toolCallID: echoCall.id), threadId: nil)

        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )
        let jsonl = try #require(files.first { $0.pathExtension == "jsonl" })
        let lines = try String(contentsOf: jsonl, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        let objects = try lines.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:]
        }

        // 1) assistant task call: answer in `content`, reasoning split out, subagent on the call.
        #expect(objects[0]["content"] as? String == "Delegating.")
        #expect(objects[0]["reasoning"] as? String == "I should look")
        let calls = objects[0]["toolCalls"] as? [[String: Any]]
        #expect(calls?.first?["name"] as? String == "task")
        #expect(calls?.first?["subagentType"] as? String == "vision")

        // 2) task result: self-describing — names its origin tool and subagent.
        #expect(objects[1]["role"] as? String == "tool")
        #expect(objects[1]["toolName"] as? String == "task")
        #expect(objects[1]["subagentType"] as? String == "vision")

        // 3) ordinary tool call: no subagent marker; run context recorded for analysis
        // (which model generated the turn, which loop round, how long it took).
        let echoCalls = objects[2]["toolCalls"] as? [[String: Any]]
        #expect(echoCalls?.first?["name"] as? String == "echo")
        #expect(echoCalls?.first?["subagentType"] == nil)
        #expect(objects[2]["modelID"] as? String == "LiquidAI/LFM2.5-8B-A1B-MLX-8bit")
        #expect(objects[2]["round"] as? Int == 2)
        #expect(objects[2]["generationSeconds"] as? Double == 1.235) // rounded to ms
        // The first append used the no-context convenience — fields omitted, not null.
        #expect(objects[0]["modelID"] == nil)

        // 4) ordinary tool result: names the tool, but carries no subagent.
        #expect(objects[3]["toolName"] as? String == "echo")
        #expect(objects[3]["subagentType"] == nil)
    }

    @Test func reasoningBlockIsPreferredOverInlineThink() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-log-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = JSONLMessageLog(directory: dir)

        // A structured reasoning block whose answer text still contains an inline `<think>`: the
        // block wins, and the answer is logged verbatim (not re-split).
        await log.append(.ai("<think>inline</think>the answer", reasoning: "block reasoning"), threadId: nil)
        // A clean answer with no reasoning at all → no `reasoning` field.
        await log.append(.ai("just an answer"), threadId: nil)

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let jsonl = try #require(files.first { $0.pathExtension == "jsonl" })
        let objects = try String(contentsOf: jsonl, encoding: .utf8)
            .split(separator: "\n").map(String.init).map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:]
            }
        #expect(objects[0]["reasoning"] as? String == "block reasoning")
        #expect(objects[0]["content"] as? String == "<think>inline</think>the answer")
        #expect(objects[1]["reasoning"] == nil)
        #expect(objects[1]["content"] as? String == "just an answer")
    }
}
