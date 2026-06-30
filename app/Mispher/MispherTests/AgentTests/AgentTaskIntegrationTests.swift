import AppKit
import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import Mispher
import Testing

/// **Hard** end-to-end task tests against the LFM2.5 8B-A1B model — the four multi-step
/// tool tasks that were reported failing in the app:
///
///  1. "what time is it and add it to my clipboard"            (current_datetime → write_clipboard)
///  2. "break down steps for baking a cake and add to todos"   (write_todos)
///  3. "read my clipboard and translate it"                    (read_clipboard → answer)
///  4. "read the command from my clipboard and add to todos"   (read_clipboard → write_todos)
///
/// Unlike `AgentIntegrationTests` (which grades capability softly via `withKnownIssue`, so
/// it never fails the build), this suite asserts the **actual outcome**: the right tools
/// ran, the side effects happened (the clipboard really holds the time, the to-do list
/// really has the steps), and — where correctness is semantic — an LLM judge confirms it.
///
/// The 8B is non-deterministic: a single run is a coin flip (it may emit a malformed tool
/// call after a long `<think>`, paste a hallucinated string, or refuse the task). So each
/// task is given a small **retry budget** and passes as soon as one attempt succeeds. That
/// makes the assertion meaningful and stable: green means "the agent *can* accomplish this
/// task end to end"; red means it could not in `maxAttempts` tries — a real regression,
/// not a coin flip. Every attempt's diagnostics are recorded so a genuine failure is
/// debuggable.
///
/// Runs only when the 8B weights are downloaded (the judge is the same model). Serialized
/// so the heavy model loads once and tool tasks never race on the shared pasteboard.
@Suite(.serialized, .modelExclusive, .enabled(if: AgentJudge.isAvailable))
@MainActor
struct AgentTaskIntegrationTests {
    private static let model = IntegrationModel.moe8B
    // Kept low: each attempt is a full multi-round 8B run, and stacking many heavy
    // generations in one process drives the MLX/Metal allocator into a segfault on
    // memory-constrained machines. Two attempts smooths the worst run-to-run noise
    // without piling on load.
    private static let maxAttempts = 2

    // MARK: - 1. Time → clipboard

    @Test func tellsTimeAndAddsItToClipboard() async {
        let manager = AgentTestHost.manager(for: Self.model)
        await passesWithin {
            let (ok, result, _) = await withClipboard(nil) {
                await manager.runAsk(
                    "What time is it? Add the current time to my clipboard.", model: Self.model
                )
            }
            // Assert on what write_clipboard was *given* (its own recorded output), not the
            // live pasteboard — the system clipboard is shared, so anything the user copies
            // mid-run would otherwise corrupt the check. A real time has digits; a
            // hallucinated string like "macparakeet: …" does not.
            let copied = result.output(of: "write_clipboard") ?? ""
            let pass =
                ok && result.used("current_datetime") && result.used("write_clipboard")
                    && copied.contains(where: \.isNumber)
            return (pass, "tools=\(result.toolsUsed) copied=\"\(copied)\"")
        }
    }

    // MARK: - 2. Cake steps → to-do list

    @Test func breaksDownCakeStepsIntoTodoList() async {
        let manager = AgentTestHost.manager(for: Self.model)
        await passesWithin {
            let (ok, result) = await manager.runAsk(
                "Break down the steps for baking a cake and add them to the to-do list.",
                model: Self.model
            )
            // Recorded as todos (not described in prose, and not emitted as an unparsed
            // tool-call string), with several distinct steps.
            let pass = ok && result.used("write_todos") && result.todos.count >= 3
            return (pass, "tools=\(result.toolsUsed) todos=\(result.todos.map(\.content))")
        }
    }

    // MARK: - 3. Read clipboard → translate

    @Test func readsClipboardAndTranslatesIt() async {
        let manager = AgentTestHost.manager(for: Self.model)
        let french = "Bonjour, comment ça va?"
        await passesWithin {
            let (ok, result, _) = await withClipboard(french) {
                await manager.runAsk(
                    "Read my clipboard and translate it to English.", model: Self.model
                )
            }
            // Deterministic: it read the clipboard and our tool returned exactly what's on it.
            let readOK =
                ok && result.used("read_clipboard")
                    && result.clipboardRead == french
                    && !result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard readOK else {
                return (false, "tools=\(result.toolsUsed) answer=\"\(result.answer)\"")
            }
            // Semantic: the reply is actually an English translation — the judge decides.
            let verdict = await AgentJudge.evaluate(
                task: "Read the macOS clipboard (the French \"\(french)\") and translate it to "
                    + "English (roughly \"Hello, how are you?\") in the reply.",
                evidence: result.evidence()
            )
            return (verdict.pass, "judge: \(verdict.reasoning)")
        }
    }

    // MARK: - 4. Read command from clipboard → break down → to-do list

    @Test func readsCommandFromClipboardAndBuildsTodoList() async {
        let manager = AgentTestHost.manager(for: Self.model)
        let command = "Preheat the oven to 180C, mix the flour and sugar, then bake for 30 minutes."
        await passesWithin {
            let (ok, result, _) = await withClipboard(command) {
                await manager.runAsk(
                    "Read the command from my clipboard, break it into steps, and add them to "
                        + "the to-do list.",
                    model: Self.model
                )
            }
            // Read the clipboard (returning the command) AND recorded the broken-down steps
            // as real todos (a malformed call would yield 0–1 garbage todos).
            let pass =
                ok && result.used("read_clipboard")
                    && result.clipboardRead == command
                    && result.used("write_todos") && result.todos.count >= 2
            return (pass, "tools=\(result.toolsUsed) todos=\(result.todos.map(\.content))")
        }
    }

    // MARK: - Helpers

    /// Run `attempt` up to `maxAttempts` times, passing as soon as it returns `pass == true`.
    /// On all-fail, records one failure with every attempt's note attached (so a genuine
    /// "the agent can't do this" is debuggable, while run-to-run model noise is tolerated).
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
            Comment(rawValue: "task not accomplished in \(Self.maxAttempts) attempts:\n"
                + notes.joined(separator: "\n"))
        )
    }

    /// Run `body` with the macOS clipboard set to `text` (nil = empty), restoring whatever
    /// was there afterwards. Returns the run's `ok` + `AskResult` plus the clipboard's
    /// final contents (so the caller can assert on side effects).
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
