import AppKit
import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import Mispher
import Testing

/// Regression tests for the ReAct **loop converging** — the bug where the directive system
/// prompt + tool list were re-templated onto the warm KV cache on every round (see
/// `MlxChatModel`/`MlxTurnSession`), re-firing the tool-call reflex. Real on-device logs
/// showed a plain "What is the current time?" calling `current_datetime` **9×** before
/// answering, and "Read my clipboard." looping `read_clipboard` **5×** then losing the
/// request. One tool call suffices for these single-step tasks, so each test asserts the
/// tool fires at most twice and a real answer comes back.
///
/// Kept separate from `AgentTaskIntegrationTests` (which grades multi-step task *success*):
/// these are cheap single-step convergence checks, runnable on their own. Real 8B; runs
/// only when the weights are downloaded. Serialized + model-exclusive so the heavy model
/// loads once and never races the shared pasteboard.
@Suite(.serialized, .modelExclusive, .enabled(if: AgentJudge.isAvailable))
@MainActor
struct AgentLoopConvergenceTests {
    private static let model = IntegrationModel.moe8B
    private static let maxAttempts = 2

    /// "What is the current time?" — before the fix this looped `current_datetime` ~9×.
    @Test func doesNotRepeatedlyCallTimeTool() async {
        let manager = AgentTestHost.manager(for: Self.model)
        await passesWithin {
            let (ok, result) = await manager.runAsk(
                "What is the current time?", model: Self.model
            )
            let timeCalls = result.started.filter { $0.name == "current_datetime" }.count
            let pass =
                ok && result.used("current_datetime") && timeCalls <= 2
                    && result.answer.contains(where: \.isNumber)
            return (pass, "current_datetime calls=\(timeCalls) answer=\"\(result.answer)\"")
        }
    }

    /// "Read my clipboard." — before the fix this looped `read_clipboard` 5× then lost the
    /// request ("a user request that is not provided").
    @Test func doesNotRepeatedlyReadClipboard() async {
        let manager = AgentTestHost.manager(for: Self.model)
        await passesWithin {
            let (ok, result, _) = await withClipboard("Bonjour le monde") {
                await manager.runAsk("Read my clipboard.", model: Self.model)
            }
            let reads = result.started.filter { $0.name == "read_clipboard" }.count
            let pass =
                ok && result.used("read_clipboard") && reads <= 2
                    && !result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (pass, "read_clipboard calls=\(reads) answer=\"\(result.answer)\"")
        }
    }

    /// "Read my clipboard and translate it" used to make the model **refuse** — claiming it
    /// had no clipboard access or translation ability (see `logs/`), contradicting the
    /// system prompt. The prompt now states plainly that it can. Assert it actually reads
    /// the clipboard and answers, rather than bailing. (Translation *quality* is graded by
    /// the heavier `AgentTaskIntegrationTests`; this just guards against the refusal.)
    @Test func doesNotRefuseToReadAndTranslateClipboard() async {
        let manager = AgentTestHost.manager(for: Self.model)
        await passesWithin {
            let (ok, result, _) = await withClipboard("Bonjour, comment ça va?") {
                await manager.runAsk(
                    "Read my clipboard and translate it to English.", model: Self.model
                )
            }
            let pass =
                ok && result.used("read_clipboard")
                    && !result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (pass, "tools=\(result.toolsUsed) answer=\"\(result.answer)\"")
        }
    }

    /// Cake planning used to collapse to **one** garbage todo and then loop, because
    /// mlx-swift-lm's tool-call parser truncated the `todos` list argument at the first
    /// comma (see `logs/`). With our own LFM2 tool-call parser the nested array survives, so
    /// the model's plan lands as several real to-do items in a single call. Asserts the
    /// structured argument now makes it through.
    @Test func plansCakeIntoMultipleTodos() async {
        let manager = AgentTestHost.manager(for: Self.model)
        await passesWithin {
            let (ok, result) = await manager.runAsk(
                "Break down the steps for baking a cake and add them to the to-do list.",
                model: Self.model
            )
            let pass = ok && result.used("write_todos") && result.todos.count >= 3
            return (pass, "todos=\(result.todos.map(\.content))")
        }
    }

    // MARK: - Helpers

    /// Run `attempt` up to `maxAttempts` times, passing as soon as one returns `pass`.
    private func passesWithin(
        _ attempt: () async -> (pass: Bool, note: String)
    ) async {
        var notes: [String] = []
        for index in 1 ... Self.maxAttempts {
            let (pass, note) = await attempt()
            notes.append("attempt \(index): \(note)")
            if pass { return }
        }
        Issue.record(
            Comment(
                rawValue: "loop did not converge in \(Self.maxAttempts) attempts:\n"
                    + notes.joined(separator: "\n")
            )
        )
    }

    /// Run `body` with the macOS clipboard set to `text`, restoring it afterwards.
    private func withClipboard(
        _ text: String?,
        _ body: () async -> (ok: Bool, result: AskResult)
    ) async -> (ok: Bool, result: AskResult, clipboard: String) {
        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        if let text { NSPasteboard.general.setString(text, forType: .string) }
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        let (ok, result) = await body()
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        return (ok, result, clipboard)
    }
}
