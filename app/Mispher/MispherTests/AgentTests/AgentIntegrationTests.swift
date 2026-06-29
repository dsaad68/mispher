import AppKit
import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import Mispher
import Testing

/// End-to-end tests that run real on-device MLX models through the full agent stack:
/// residency/load → `MlxChatModel` → `ChatSession` → ReAct loop → tool dispatch → events.
///
/// Each test runs once per model in `IntegrationModel.available` (LFM2.5 1.2B Instruct
/// bf16 and LFM2.5 8B-A1B 8-bit).
///
/// Two kinds of checks:
///  • **Hard** (`#expect`) — what *our code* guarantees: a tool that is called returns
///    the correct value, side effects happen, the run completes. These fail the build.
///  • **Capability** (`reportCapability`, via `withKnownIssue(isIntermittent:)`) — whether
///    a model *chooses* to use the right tools and *accomplishes* an open-ended task,
///    graded by the 8B LLM-judge. Small on-device models are non-deterministic, so these
///    are reported (and visible in the log when they fail) but do NOT break the build.
///
/// Serialized so the heavy models load once (via `AgentTestHost`) and never run
/// concurrently; skipped entirely when the weights aren't downloaded.
@Suite(.serialized, .modelExclusive)
@MainActor
struct AgentIntegrationTests {
    /// Report a model-capability outcome without failing the build (see suite docs).
    private func reportCapability(_ pass: Bool, _ comment: Comment) {
        withKnownIssue(comment, isIntermittent: true) { #expect(pass) }
    }

    // MARK: - Hard: the model loads and streams

    @Test(arguments: IntegrationModel.available)
    func streamsAnAnswer(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        var answer = ""
        var completed = false
        let ok = await manager.askAgent(
            "Reply with exactly one word: pong.", modelId: model
        ) { event in
            switch event {
            case .token(let chunk, _): answer += chunk
            case .completed: completed = true
            default: break
            }
        }
        #expect(ok)
        #expect(completed)
        #expect(!answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Hard tool correctness + soft model capability

    @Test(.enabled(if: AgentJudge.isAvailable), arguments: IntegrationModel.available)
    func usesCalculatorTool(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        let (ok, result) = await manager.runAsk(
            "Use the calculator tool to compute 21 * 2. Then reply with only the result.",
            model: model
        )
        #expect(ok)
        // Capability: the model chose a calculator expression and reported the result.
        // (The calculator's own correctness is covered deterministically by unit tests.)
        reportCapability(
            result.output(of: "calculator") == "42" || result.answer.contains("42"),
            "calc=\(result.output(of: "calculator") ?? "—") answer: \(result.answer)"
        )
    }

    @Test(arguments: IntegrationModel.available)
    func readsTheClipboard(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        let marker = "mispher-clip-7F3K"
        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(marker, forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let (ok, result) = await manager.runAsk(
            "Read my clipboard and tell me the exact text on it.", model: model
        )
        #expect(ok)
        // Hard: when read_clipboard runs, it returns exactly what's on the clipboard
        // (unwrapped from its `{"clipboard_text": …}` envelope).
        if let text = result.clipboardRead { #expect(text == marker) }
        // Capability: did the model surface the clipboard text?
        reportCapability(
            result.clipboardRead == marker || result.answer.contains(marker),
            "answer: \(result.answer)"
        )
    }

    @Test(arguments: IntegrationModel.available)
    func writesTheClipboard(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let (ok, result) = await manager.runAsk(
            "Copy the word pineapple to my clipboard using your tools.", model: model
        )
        #expect(ok)
        // Capability: the model chose to copy via write_clipboard and the word landed on
        // the pasteboard. (write_clipboard's own correctness is unit-tested.)
        let pasteboard = NSPasteboard.general.string(forType: .string) ?? ""
        reportCapability(
            result.used("write_clipboard") && pasteboard.lowercased().contains("pineapple"),
            "tools: \(result.toolsUsed) clipboard: \(pasteboard)"
        )
    }

    // MARK: - Capability: judge-graded agentic tasks

    @Test(.enabled(if: AgentJudge.isAvailable), arguments: IntegrationModel.available)
    func chatRemembersAcrossTurns(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        guard let mlxModel = MlxModel.catalog.first(where: { $0.id == model }) else { return }
        _ = await manager.askAgent("Hello.", modelId: model) { _ in }

        await manager.sendAgent(mlxModel, prompt: "My name is Zorp. Remember it.", imageURL: nil)
        await manager.sendAgent(
            mlxModel, prompt: "What is my name? Reply with just the name.", imageURL: nil
        )
        let reply = manager.transcript(for: mlxModel).last { $0.role == .model }?.text ?? ""

        let verdict = await AgentJudge.evaluate(
            task: "Earlier the user said their name is Zorp, then asked 'What is my name?'. "
                + "The reply should say Zorp.",
            evidence: "Assistant's reply: \(reply)"
        )
        reportCapability(verdict.pass, "\(verdict.reasoning)")
    }

    @Test(.enabled(if: AgentJudge.isAvailable), arguments: IntegrationModel.available)
    func tellsTimeAndCopiesItToClipboard(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let (ok, result) = await manager.runAsk(
            "What time is it? Add the current time to my clipboard.", model: model
        )
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        #expect(ok)

        let verdict = await AgentJudge.evaluate(
            task: "Tell the user the current time AND copy the current time onto the macOS clipboard.",
            evidence: result.evidence(finalClipboard: clipboard)
        )
        reportCapability(verdict.pass, "\(verdict.reasoning)")
    }

    @Test(.enabled(if: AgentJudge.isAvailable), arguments: IntegrationModel.available)
    func breaksDownCakeStepsIntoTodoList(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        let (ok, result) = await manager.runAsk(
            "Break down the steps for baking a cake and add them to the to-do list.", model: model
        )
        #expect(ok)

        let verdict = await AgentJudge.evaluate(
            task: "Break baking a cake into multiple steps and record them in the to-do list "
                + "(via write_todos), not just describe them.",
            evidence: result.evidence()
        )
        reportCapability(verdict.pass, "\(verdict.reasoning)")
    }

    @Test(.enabled(if: AgentJudge.isAvailable), arguments: IntegrationModel.available)
    func readsClipboardAndTranslatesIt(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Bonjour, comment ça va?", forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let (ok, result) = await manager.runAsk(
            "Read my clipboard and translate it to English.", model: model
        )
        #expect(ok)

        let verdict = await AgentJudge.evaluate(
            task: "Read the macOS clipboard (the French 'Bonjour, comment ça va?') and "
                + "translate it to English (roughly 'Hello, how are you?').",
            evidence: result.evidence()
        )
        reportCapability(verdict.pass, "\(verdict.reasoning)")
    }

    @Test(.enabled(if: AgentJudge.isAvailable), arguments: IntegrationModel.available)
    func readsCommandFromClipboardAndBuildsTodoList(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "Preheat the oven to 180C, mix the flour and sugar, then bake for 30 minutes.",
            forType: .string
        )
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let (ok, result) = await manager.runAsk(
            "Read the command from my clipboard, break it into steps, and add them to the to-do list.",
            model: model
        )
        #expect(ok)

        let verdict = await AgentJudge.evaluate(
            task: "Read the multi-step command from the macOS clipboard, break it into "
                + "individual steps, and record them in the to-do list (via write_todos).",
            evidence: result.evidence()
        )
        reportCapability(verdict.pass, "\(verdict.reasoning)")
    }

    @Test(.enabled(if: AgentJudge.isAvailable), arguments: IntegrationModel.available)
    func answersConversationallyWithoutNeedlessTools(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        let (ok, result) = await manager.runAsk(
            "Write a short two-line rhyme about the sea.", model: model
        )
        #expect(ok)

        let verdict = await AgentJudge.evaluate(
            task: "Write a short two-line rhyme about the sea — a creative task needing no tools.",
            evidence: result.evidence()
        )
        reportCapability(verdict.pass, "\(verdict.reasoning)")
    }

    @Test(.enabled(if: AgentJudge.isAvailable), arguments: IntegrationModel.available)
    func solvesArithmeticWordProblemWithCalculator(model: String) async {
        let manager = AgentTestHost.manager(for: model)
        let (ok, result) = await manager.runAsk(
            "Use the calculator to work out (15 + 5) * 3, then tell me the result.", model: model
        )
        #expect(ok)

        let verdict = await AgentJudge.evaluate(
            task: "Compute (15 + 5) * 3, which is 60, using the calculator and report 60.",
            evidence: result.evidence()
        )
        reportCapability(verdict.pass, "\(verdict.reasoning)")
    }
}
