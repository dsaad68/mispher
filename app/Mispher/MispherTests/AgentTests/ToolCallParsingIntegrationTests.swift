import AppKit
import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import Mispher
import Testing

/// Real-8B integration tests for our own LFM2 tool-call parsing (`LFM2ToolCalls` /
/// `LFM2ToolCallStream`) — the fix for mlx-swift-lm's parser truncating list/dict tool
/// arguments at the first comma (see `STEPS/BUG-REPORT.md`). Each test drives the actual 8B
/// agent and asserts that a structured `write_todos(todos=[…])` call survives parsing end to
/// end: the nested array lands as real to-do items, including content that itself contains
/// commas (the exact thing the built-in parser dropped).
///
/// Runs only when the 8B weights are downloaded. Serialized + model-exclusive so the heavy
/// model loads once and the tests never race the shared pasteboard.
@Suite(.serialized, .modelExclusive, .enabled(if: AgentJudge.isAvailable))
@MainActor
struct ToolCallParsingIntegrationTests {
    private static let model = IntegrationModel.moe8B
    private static let maxAttempts = 2

    /// A clean multi-item request must parse into the full set of to-dos — not collapse to
    /// one item (the old failure) or drop items after the first comma.
    @Test func parsesExplicitMultiItemListIntoTodos() async {
        let manager = AgentTestHost.manager(for: Self.model)
        await passesWithin {
            let (ok, result) = await manager.runAsk(
                "Add these four items to my to-do list: buy milk, call the dentist, "
                    + "water the plants, and pay rent.",
                model: Self.model
            )
            let pass = ok && result.used("write_todos") && result.todos.count >= 4
            return (pass, "count=\(result.todos.count) todos=\(result.todos.map(\.content))")
        }
    }

    /// Two tool rounds: read a multi-step command from the clipboard, then record the broken-
    /// down steps as a structured to-do list. Exercises a `write_todos` array argument built
    /// from content the model read at run time.
    @Test func parsesCommandFromClipboardIntoTodos() async {
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
            let pass =
                ok && result.used("read_clipboard")
                    && result.clipboardRead == command
                    && result.used("write_todos") && result.todos.count >= 2
            return (pass, "tools=\(result.toolsUsed) todos=\(result.todos.map(\.content))")
        }
    }

    /// The direct regression for the parser bug: a to-do whose **content contains commas**.
    /// The built-in parser truncated the argument at the first comma, so a comma could never
    /// survive inside an item; with our parser the quoted string is preserved intact.
    @Test func preservesCommasInsideTodoContent() async {
        let manager = AgentTestHost.manager(for: Self.model)
        await passesWithin {
            let (ok, result) = await manager.runAsk(
                "Add exactly two items to my to-do list. The first item's text is exactly: "
                    + "\"Buy flour, sugar, and eggs\". The second item's text is exactly: "
                    + "\"Preheat the oven\".",
                model: Self.model
            )
            let hasCommaItem = result.todos.contains { $0.content.contains(",") }
            let pass = ok && result.used("write_todos") && result.todos.count >= 2 && hasCommaItem
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
                rawValue: "structured tool call did not parse in \(Self.maxAttempts) attempts:\n"
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
