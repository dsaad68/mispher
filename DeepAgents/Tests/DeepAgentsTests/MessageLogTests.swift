@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// The developer message log: a thread's messages are appended to a JSONL file, in the
/// order they appear, with tool calls and their results linked by id.
struct MessageLogTests {
    /// A fresh temp directory that's cleaned up after `body`.
    private func withTempDirectory(_ body: (URL) async throws -> Void) async rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-msglog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    /// The single `.jsonl` file the log wrote into `dir` (its name is a timestamp).
    private func jsonlFile(in dir: URL) throws -> URL {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
                ?? []
        return try #require(files.first { $0.pathExtension == "jsonl" })
    }

    private func readJSONL(_ url: URL) throws -> [[String: Any]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try content.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(object as? [String: Any])
        }
    }

    @Test func logsThreadMessagesInSequenceWithToolLinkage() async throws {
        try await withTempDirectory { dir in
            let log = JSONLMessageLog(directory: dir)
            let call = AgentToolCall(name: "echo", arguments: ["text": .string("hi")])
            let agent = createAgent(
                model: FakeChatModel(answer: "done", toolCalls: [call]),
                tools: [EchoTool()],
                messageLog: log
            )

            _ = await agent.collect([.human("use it")], threadId: "chat-1")

            let entries = try readJSONL(jsonlFile(in: dir))
            // The full structured exchange, in order.
            #expect(entries.map { $0["role"] as? String } == ["human", "ai", "tool", "ai"])
            #expect(entries[0]["content"] as? String == "use it")
            #expect(entries[3]["content"] as? String == "done")

            // The assistant turn records its tool call; the tool result links back by id.
            let toolCalls = entries[1]["toolCalls"] as? [[String: Any]]
            #expect(toolCalls?.first?["name"] as? String == "echo")
            let callID = toolCalls?.first?["id"] as? String
            #expect(callID != nil)
            #expect(entries[2]["toolCallID"] as? String == callID)
            #expect(entries[2]["content"] as? String == "echo: hi")

            // Every line carries the thread id.
            #expect(entries.allSatisfy { $0["threadId"] as? String == "chat-1" })
        }
    }

    @Test func accumulatesAcrossRunsOnTheSameThread() async throws {
        try await withTempDirectory { dir in
            let log = JSONLMessageLog(directory: dir)
            let memory = InMemoryCheckpointer()
            let agent = createAgent(
                model: FakeChatModel(answer: "ok"), memory: memory, messageLog: log
            )

            _ = await agent.collect([.human("first")], threadId: "t")
            _ = await agent.collect([.human("second")], threadId: "t")

            // One log instance ⇒ one file; both runs append to it, in order.
            let entries = try readJSONL(jsonlFile(in: dir))
            #expect(entries.map { $0["role"] as? String } == ["human", "ai", "human", "ai"])
            #expect(entries[0]["content"] as? String == "first")
            #expect(entries[2]["content"] as? String == "second")
        }
    }

    @Test func fileIsNamedByCreationTimestamp() async throws {
        try await withTempDirectory { dir in
            let log = JSONLMessageLog(directory: dir)
            let agent = createAgent(model: FakeChatModel(answer: "hi"), messageLog: log)

            _ = await agent.collect([.human("yo")], threadId: "any/thread:id")

            // The filename is the creation moment plus a short uniqueness suffix (so two
            // runs started within the same second don't interleave into one file):
            // YYYY-MM-DD-HH-MM-SS-xxxx.jsonl. The thread id does not affect it — it's
            // recorded inside each line instead.
            let name = try jsonlFile(in: dir).lastPathComponent
            let pattern = #"^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-[0-9a-f]{4}\.jsonl$"#
            #expect(name.range(of: pattern, options: .regularExpression) != nil, "name: \(name)")

            let entries = try readJSONL(jsonlFile(in: dir))
            #expect(entries.allSatisfy { $0["threadId"] as? String == "any/thread:id" })
        }
    }
}
