import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import Mispher
import MLX
import Testing

/// Process-wide async mutex so the heavy model-loading integration tests never run
/// concurrently. Swift Testing runs suites in parallel by default; two resident MLX models
/// (or two generations at once) exhaust unified memory and crash the test host. Every
/// model-using test acquires this for its whole duration via the `.modelExclusive` trait.
actor ModelTestLock {
    static let shared = ModelTestLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Runs each test it covers under `ModelTestLock`, so model-using integration suites are
/// mutually exclusive even though Swift Testing parallelizes suites. Apply to a suite to
/// serialize all of its (and its peers') model runs: `@Suite(.serialized, .modelExclusive)`.
struct ModelExclusiveTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        // Lock only around individual test cases. The recursive suite trait is also scoped
        // at the suite node (testCase == nil); holding the lock there while the suite's own
        // test cases try to acquire it would deadlock the non-reentrant mutex.
        guard testCase != nil else {
            try await function()
            return
        }
        await ModelTestLock.shared.acquire()
        do {
            try await function()
        } catch {
            MLX.Memory.clearCache()
            await ModelTestLock.shared.release()
            throw error
        }
        // Free the Metal buffer cache between model tests so generations don't accumulate
        // unified memory across a serialized run (which OOM-crashes the test host).
        MLX.Memory.clearCache()
        await ModelTestLock.shared.release()
    }
}

extension Trait where Self == ModelExclusiveTrait {
    /// Serialize this suite's model runs against every other `.modelExclusive` suite.
    static var modelExclusive: Self { ModelExclusiveTrait() }
}

/// Models and host used by the agent integration tests.
enum IntegrationModel {
    /// LFM2.5 1.2B Instruct (bf16) — a small, capable instruct model.
    static let instruct1_2B = "LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16"
    /// LFM2.5 8B-A1B (8-bit) — the MoE model (also emits `<think>` reasoning).
    static let moe8B = "LiquidAI/LFM2.5-8B-A1B-MLX-8bit"

    /// The models every integration test is parameterized over (one run each).
    static let all = [instruct1_2B, moe8B]

    /// Of `all`, those already present in the local Hugging Face cache. The integration
    /// tests only run for downloaded models, so the suite never triggers a (multi-GB)
    /// download and is skipped cleanly when the weights aren't there.
    static var available: [String] { all.filter(isDownloaded) }

    /// Whether `repoId` is in the local Hugging Face cache. Mirrors the cache layout
    /// used by `swift-huggingface` / `mlx-swift-lm`.
    static func isDownloaded(_ repoId: String) -> Bool {
        let fileManager = FileManager.default
        let hubBase: URL
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"] {
            hubBase = URL(fileURLWithPath: hfHome).appendingPathComponent("hub")
        } else {
            hubBase = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub")
        }
        let repoDir = hubBase.appendingPathComponent(
            "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        )
        let snapshots = repoDir.appendingPathComponent("snapshots")
        guard
            let hashes = try? fileManager.contentsOfDirectory(
                at: snapshots, includingPropertiesForKeys: nil
            )
        else { return false }
        return hashes.contains {
            fileManager.fileExists(atPath: $0.appendingPathComponent("config.json").path)
        }
    }
}

/// Keeps one `MlxModelManager` per model id alive for the whole integration suite, so
/// each (heavy) model is loaded exactly once — the first `askAgent` loads it and later
/// calls reuse the resident container — instead of reloading for every test.
@MainActor
enum AgentTestHost {
    private static var managers: [String: MlxModelManager] = [:]

    static func manager(for modelId: String) -> MlxModelManager {
        if let existing = managers[modelId] { return existing }
        let manager = MlxModelManager()
        managers[modelId] = manager
        return manager
    }
}

/// What an agent run produced — the streamed answer plus the tools it called (with
/// their inputs/outputs) and any to-do plan it wrote. Used by the integration tests to
/// assert multi-tool chaining.
struct AskResult {
    var answer = ""
    var started: [(name: String, input: String)] = []
    var completed: [(name: String, output: String)] = []
    var todos: [TodoItem] = []

    var toolsUsed: [String] { started.map(\.name) }
    func used(_ name: String) -> Bool { started.contains { $0.name == name } }
    func output(of name: String) -> String? { completed.last { $0.name == name }?.output }

    /// The text `read_clipboard` reported, unwrapped from its documented `{"clipboard_text": …}`
    /// JSON envelope, or nil if the tool wasn't called (or its output didn't decode). Clipboard
    /// assertions compare against this rather than the raw tool output, which is the JSON object.
    var clipboardRead: String? {
        guard let output = output(of: "read_clipboard"),
              let data = output.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return object["clipboard_text"]
    }

    /// A plain-text summary of what the assistant did, for the LLM judge: the tools it
    /// called and their results, any side effects, the to-do plan, and the final answer.
    func evidence(finalClipboard: String? = nil) -> String {
        var lines: [String] = []
        lines.append("Tools called: \(toolsUsed.isEmpty ? "none" : toolsUsed.joined(separator: ", "))")
        for call in completed {
            lines.append("• \(call.name) returned: \(call.output)")
        }
        if let finalClipboard {
            lines.append("Clipboard now contains: \"\(finalClipboard)\"")
        }
        if !todos.isEmpty {
            let items = todos.map { "[\($0.status.rawValue)] \($0.content)" }.joined(separator: "; ")
            lines.append("To-do list now: \(items)")
        }
        lines.append("Final answer to the user: \(answer)")
        return lines.joined(separator: "\n")
    }
}

/// LLM-as-judge: uses the strong model (LFM2.5 8B-A1B) to decide whether an agent run
/// accomplished its task, given structured evidence. This makes the integration
/// assertions robust to wording instead of brittle string matching.
enum AgentJudge {
    /// Whether the 8B judge model is available to run (nonisolated: just a file check,
    /// so it can be used in a `.enabled(if:)` trait).
    static var isAvailable: Bool { IntegrationModel.isDownloaded(IntegrationModel.moe8B) }

    @MainActor
    static func evaluate(task: String, evidence: String) async -> (pass: Bool, reasoning: String) {
        let manager = AgentTestHost.manager(for: IntegrationModel.moe8B)
        let prompt = """
        You are a strict QA judge for an on-device AI assistant that has these tools: \
        current_datetime, calculator, read_clipboard, write_clipboard, write_todos. \
        Note: the assistant translates and summarizes text with its own ability — \
        there is NO separate translation tool, so reading the clipboard and then \
        giving the translation directly in its answer is correct and complete.

        Decide whether the assistant correctly and fully accomplished the user's task. \
        Calling the right tools and producing the right side effects (clipboard \
        contents, to-do items) matters more than the exact wording. If the assistant \
        claimed it could not access something it has a tool for, only asked the user \
        instead of acting, or skipped part of the task, that is a FAIL.

        USER TASK:
        \(task)

        EVIDENCE OF WHAT THE ASSISTANT ACTUALLY DID:
        \(evidence)

        Explain briefly, then end your reply with the single word PASS or FAIL on its \
        own final line.
        """
        var reply = ""
        _ = await manager.ask(prompt, modelId: IntegrationModel.moe8B) { reply += $0 }

        // The 8B is a reasoning model that always emits a long <think> block, so a fixed
        // "first line" parse is unreliable. Take whichever verdict it states LAST (its
        // conclusion), scanning the whole reply.
        let upper = reply.uppercased()
        let lastPass = upper.range(of: "PASS", options: .backwards)?.lowerBound
        let lastFail = upper.range(of: "FAIL", options: .backwards)?.lowerBound
        let pass: Bool
        switch (lastPass, lastFail) {
        case let (passIndex?, failIndex?): pass = passIndex > failIndex
        case (_?, nil): pass = true
        default: pass = false
        }
        return (pass, reply)
    }
}

extension MlxModelManager {
    /// Run the Ask agent and collect everything it did (answer + tool activity + todos).
    func runAsk(_ prompt: String, model: String) async -> (ok: Bool, result: AskResult) {
        var result = AskResult()
        // Keep only the final round's text as the answer — interim reasoning from a
        // tool-calling round is rolled back at its `roundCompleted` boundary.
        var committedLength = 0
        let ok = await askAgent(prompt, modelId: model) { event in
            switch event {
            case .token(let chunk, _): result.answer += chunk
            case .roundCompleted(let hadToolCalls):
                if hadToolCalls {
                    result.answer = String(result.answer.prefix(committedLength))
                } else {
                    committedLength = result.answer.count
                }
            case .toolStarted(let name, let input): result.started.append((name, input))
            case .toolCompleted(let name, let output, _, _): result.completed.append((name, output))
            case .todosUpdated(let todos): result.todos = todos
            default: break
            }
        }
        return (ok, result)
    }
}
