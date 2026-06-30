import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
@testable import Mispher
import Testing

/// `AgentTimelineBuilder` folds the agent's event stream into an ordered reasoning / tool /
/// todo timeline. These cover the ordering and the special handling (write_todos shown as a
/// checklist not a chip, tool output attachment, `<think>` extraction, live streaming text).
struct AgentTimelineBuilderTests {
    private func build(_ events: [AgentEvent]) -> AgentTimelineBuilder {
        var builder = AgentTimelineBuilder()
        for event in events { builder.consume(event) }
        return builder
    }

    /// A full task: reason → write_todos (shown as the plan) → reason → answer, in order.
    @Test func buildsOrderedReasoningTodoAnswerTimeline() {
        let todos = [
            TodoItem(content: "Gather ingredients", status: .pending),
            TodoItem(content: "Mix", status: .pending),
            TodoItem(content: "Bake", status: .pending)
        ]
        let builder = build([
            .token("<think>plan the cake</think>", isFinal: false),
            .roundCompleted(hadToolCalls: true),
            .toolStarted(name: "write_todos", input: "todos=…"),
            .toolCompleted(name: "write_todos", result: "Updated todo list: 3 items"),
            .todosUpdated(todos),
            .token("<think>looks good</think>Here are the steps.", isFinal: false),
            .roundCompleted(hadToolCalls: false),
            .completed
        ])

        // Reasoning, then the to-do plan (write_todos itself is NOT a tool chip), then the
        // final round's reasoning — in order.
        #expect(builder.steps.count == 3)
        if case .reasoning(let r) = builder.steps[0].kind { #expect(r == "plan the cake") } else {
            Issue.record("step 0 not reasoning")
        }
        if case .todos(let t) = builder.steps[1].kind { #expect(t.count == 3) } else {
            Issue.record("step 1 not todos")
        }
        if case .reasoning(let r) = builder.steps[2].kind { #expect(r == "looks good") } else {
            Issue.record("step 2 not reasoning")
        }
        #expect(builder.answer == "Here are the steps.")
        #expect(builder.streamingText.isEmpty)
    }

    /// A non-todo tool becomes a chip whose output is attached when it completes.
    @Test func nonTodoToolBecomesChipWithOutput() {
        let builder = build([
            .token("<think>reading</think>", isFinal: false),
            .roundCompleted(hadToolCalls: true),
            .toolStarted(name: "read_clipboard", input: ""),
            .toolCompleted(name: "read_clipboard", result: "hello world"),
            .token("It says hello world.", isFinal: false),
            .roundCompleted(hadToolCalls: false)
        ])

        #expect(builder.steps.count == 2)
        guard case .tool(let name, _, let output, _, _, _) = builder.steps[1].kind else {
            Issue.record("step 1 not a tool")
            return
        }
        #expect(name == "read_clipboard")
        #expect(output == "hello world")
        #expect(builder.answer == "It says hello world.")
    }

    /// A `task` delegation streams its subagent's output into the tool step (live, labeled with the
    /// subagent) and commits the final result once it completes.
    @Test func taskStepStreamsSubagentOutputAndLabel() {
        var builder = AgentTimelineBuilder()
        builder.consume(.toolStarted(name: "task", input: "subagent_type: vision"))
        builder.consume(.toolProgress(name: "task", subagent: "vision", delta: "")) // label only
        builder.consume(.toolProgress(name: "task", subagent: "vision", delta: "I see "))

        // Mid-stream: live output accumulates, the subagent is attached, not yet done.
        guard case .tool(_, _, let mid, _, let sub1, let done1) = builder.steps.last?.kind else {
            Issue.record("no tool step mid-stream")
            return
        }
        #expect(mid == "I see ")
        #expect(sub1 == "vision")
        #expect(done1 == false)

        builder.consume(.toolProgress(name: "task", subagent: "vision", delta: "an error."))
        builder.consume(.toolCompleted(name: "task", result: "I see an error."))

        guard case .tool(let name, _, let output, _, let sub2, let done2) = builder.steps.last?.kind
        else {
            Issue.record("no tool step after completion")
            return
        }
        #expect(name == "task")
        #expect(sub2 == "vision")
        #expect(output == "I see an error.")
        #expect(done2 == true)
        #expect(builder.steps.count == 1) // one step, updated in place
    }

    @Test func toolFailureShowsWarningOutput() {
        let builder = build([
            .token("", isFinal: false),
            .roundCompleted(hadToolCalls: true),
            .toolStarted(name: "calculator", input: "1/0"),
            .toolFailed(name: "calculator", error: "division by zero")
        ])
        guard case .tool(_, _, let output, _, _, _) = builder.steps.last?.kind else {
            Issue.record("no tool step")
            return
        }
        #expect(output == "⚠️ division by zero")
    }

    @Test func finalAnswerStripsThinkIntoAReasoningStep() {
        let builder = build([
            .token("<think>compose the reply</think>The answer.", isFinal: false),
            .roundCompleted(hadToolCalls: false)
        ])
        #expect(builder.answer == "The answer.")
        #expect(builder.steps.count == 1)
        if case .reasoning(let r) = builder.steps.first?.kind {
            #expect(r == "compose the reply")
        } else {
            Issue.record("expected a reasoning step")
        }
    }

    @Test func streamingTextHoldsCurrentRoundUntilBoundary() {
        // Mid-round: text streams into `streamingText`; nothing is committed yet.
        let builder = build([
            .token("partial reasoning so", isFinal: false),
            .token(" far", isFinal: false)
        ])
        #expect(builder.streamingText == "partial reasoning so far")
        #expect(builder.steps.isEmpty)
        #expect(builder.answer.isEmpty)
    }

    @Test func emptyReasoningRoundAddsNoStep() {
        let builder = build([
            .token("", isFinal: false),
            .roundCompleted(hadToolCalls: true)
        ])
        #expect(builder.steps.isEmpty)
    }

    /// Two write_todos updates appear as two checklist snapshots, in order (showing the plan
    /// evolving), with no redundant tool chips.
    @Test func multipleTodoUpdatesAppearInSequence() {
        let first = [TodoItem(content: "Step one", status: .pending)]
        let second = [
            TodoItem(content: "Step one", status: .completed),
            TodoItem(content: "Step two", status: .pending)
        ]
        let builder = build([
            .token("<think>a</think>", isFinal: false), .roundCompleted(hadToolCalls: true),
            .toolStarted(name: "write_todos", input: "…"), .todosUpdated(first),
            .token("<think>b</think>", isFinal: false), .roundCompleted(hadToolCalls: true),
            .toolStarted(name: "write_todos", input: "…"), .todosUpdated(second)
        ])
        let todoSnapshots = builder.steps.compactMap { step -> [TodoItem]? in
            if case .todos(let t) = step.kind { return t }
            return nil
        }
        #expect(todoSnapshots.count == 2)
        #expect(todoSnapshots[0].count == 1)
        #expect(todoSnapshots[1].count == 2)
        // No tool chips for write_todos.
        #expect(!builder.steps.contains { if case .tool = $0.kind { return true } else { return false } })
    }

    // MARK: - The dedicated reasoning channel (`.reasoningToken`)

    @Test func reasoningTokenChannelBecomesAReasoningStep() {
        let builder = build([
            .reasoningToken("planning on its own channel"),
            .token("the answer", isFinal: false),
            .roundCompleted(hadToolCalls: false)
        ])
        #expect(builder.answer == "the answer")
        #expect(builder.steps.count == 1)
        if case .reasoning(let r) = builder.steps.first?.kind {
            #expect(r == "planning on its own channel")
        } else {
            Issue.record("expected a reasoning step from the reasoning channel")
        }
    }

    @Test func channelReasoningMergesWithInlineThinkFallback() {
        // A model that streams some reasoning on the channel AND inlines a `<think>` in its answer:
        // both are merged into the round's reasoning step.
        let builder = build([
            .reasoningToken("from the channel"),
            .token("<think>and inline</think>the answer", isFinal: false),
            .roundCompleted(hadToolCalls: false)
        ])
        #expect(builder.answer == "the answer")
        if case .reasoning(let r) = builder.steps.first?.kind {
            #expect(r.contains("from the channel"))
            #expect(r.contains("and inline"))
        } else {
            Issue.record("expected a merged reasoning step")
        }
    }
}
