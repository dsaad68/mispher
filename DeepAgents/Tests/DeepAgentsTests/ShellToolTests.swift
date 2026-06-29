@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// ``ShellTool`` output formatting, ``ProcessRunner``'s live-streaming path, and the
/// middleware-level block.
struct ShellToolTests {
    private func shellCall(_ command: String) -> ToolCallRequest {
        ToolCallRequest(
            call: AgentToolCall(id: UUID(), name: "shell", arguments: ["command": .string(command)]),
            state: AgentState()
        )
    }

    @Test func blockMessageExposesItsReasonForTheRedBadge() {
        let reason = "privilege escalation (sudo) is not permitted."
        #expect(ShellBlock.reason(in: ShellBlock.message(reason)) == reason)
        #expect(ShellBlock.reason(in: ReactAgent.errorJSON(ShellBlock.message(reason))) == reason)
        #expect(ShellBlock.reason(in: ReactAgent.errorJSON("some unrelated tool failure")) == nil)
    }

    @Test func middlewareThrowsForBlockedCommandsAndPassesOthers() async throws {
        let middleware = ShellToolsMiddleware(root: WorkspaceRoot())

        let allowed = try await middleware.wrapToolCall(shellCall("echo hi")) { _ in
            AgentMessage.tool("ran", toolCallID: UUID())
        }
        #expect(allowed.text == "ran")

        await #expect(throws: ShellBlockedError.self) {
            _ = try await middleware.wrapToolCall(shellCall("sudo rm -rf /")) { _ in
                Issue.record("the handler must not run for a blocked command")
                return AgentMessage.tool("ran", toolCallID: UUID())
            }
        }
    }

    @Test func formatCombinesStreamsAndAnnotatesFailures() {
        #expect(ShellTool.format(.init(stdout: "hi", stderr: "", status: 0, timedOut: false), timeout: 60) == "hi")
        #expect(ShellTool.format(.init(stdout: "", stderr: "", status: 0, timedOut: false), timeout: 60) == "(no output)")

        let failed = ShellTool.format(.init(stdout: "out", stderr: "boom", status: 2, timedOut: false), timeout: 60)
        #expect(failed.contains("out") && failed.contains("boom") && failed.contains("status 2"))

        let timed = ShellTool.format(.init(stdout: "", stderr: "", status: 15, timedOut: true), timeout: 5)
        #expect(timed.contains("timed out after 5s"))
    }

    /// A small reference sink so the `@Sendable` `onOutput` can accumulate across threads.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func add(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    @Test func streamsChunksWhileCapturingTheFullResult() async throws {
        let collector = Collector()
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", "printf foo; printf bar"],
            onOutput: { collector.add($0) }
        )
        #expect(result.stdout == "foobar") // authoritative capture
        #expect(collector.value == "foobar") // and it was streamed live
    }
}
