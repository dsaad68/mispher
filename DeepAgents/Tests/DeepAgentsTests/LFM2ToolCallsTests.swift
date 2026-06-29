@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import MLXLMCommon
import Testing

/// Unit tests for our own LFM2 tool-call parsing — the fix for mlx-swift-lm's
/// `PythonicToolCallParser`, which truncates list/dict arguments at the first comma. These
/// cover the exact shapes the 8B emits (nested arrays of objects, single quotes, commas and
/// parens inside string values) plus the streaming splitter that removes the tag spans.
struct LFM2ToolCallsTests {
    // MARK: - Argument parsing

    /// The cake case: a list-of-objects argument with commas *inside* the content strings.
    /// The built-in parser truncates this at the first comma; ours must keep all items.
    @Test func parsesNestedArrayOfObjects() {
        let block =
            "[write_todos(todos=[{'content': 'Gather ingredients (flour, sugar, eggs)', "
                + "'status': 'pending'}, {'content': 'Preheat the oven to 175°C', 'status': "
                + "'pending'}, {'content': 'Mix, then bake for 30 minutes', 'status': 'pending'}])]"
        let calls = LFM2ToolCalls.parse(block)

        #expect(calls.count == 1)
        #expect(calls.first?.name == "write_todos")
        guard case .array(let items)? = calls.first?.arguments["todos"] else {
            Issue.record("todos was not an array: \(String(describing: calls.first?.arguments))")
            return
        }
        #expect(items.count == 3)
        guard case .object(let first) = items[0] else {
            Issue.record("first item not an object")
            return
        }
        // Commas and parens inside the quoted content are preserved (not split on).
        #expect(first["content"] == .string("Gather ingredients (flour, sugar, eggs)"))
        #expect(first["status"] == .string("pending"))
        guard case .object(let third) = items[2] else {
            Issue.record("third item not an object")
            return
        }
        #expect(third["content"] == .string("Mix, then bake for 30 minutes"))
    }

    @Test func handlesBothQuoteStyles() {
        let single = LFM2ToolCalls.parse("[write_clipboard(text='hi there')]")
        let double = LFM2ToolCalls.parse("[write_clipboard(text=\"hi there\")]")
        #expect(single.first?.arguments["text"] == .string("hi there"))
        #expect(double.first?.arguments["text"] == .string("hi there"))
    }

    @Test func preservesCommasParensAndEscapesInStrings() {
        let calls = LFM2ToolCalls.parse(#"[write_clipboard(text='a, b (c) and it\'s fine')]"#)
        #expect(calls.first?.arguments["text"] == .string("a, b (c) and it's fine"))
    }

    @Test func parsesNoArgumentCall() {
        let calls = LFM2ToolCalls.parse("[current_datetime()]")
        #expect(calls.count == 1)
        #expect(calls.first?.name == "current_datetime")
        #expect(calls.first?.arguments.isEmpty == true)
    }

    /// MCP tool names are namespaced `server__tool` and can contain hyphens (e.g. a server named
    /// "parallel-search"). The identifier parse must keep the hyphen, or the whole call parses to
    /// nothing and is wrongly flagged "malformed" - exactly the loop seen with Parallel's search.
    @Test func parsesHyphenatedMCPToolName() {
        let calls = LFM2ToolCalls.parse(
            "[parallel-search__web_search(search_queries='baked potatoes', "
                + "objective='Find a baked potato recipe')]"
        )
        #expect(calls.count == 1)
        #expect(calls.first?.name == "parallel-search__web_search")
        #expect(calls.first?.arguments["search_queries"] == .string("baked potatoes"))
        #expect(calls.first?.arguments["objective"] == .string("Find a baked potato recipe"))
    }

    /// The array-argument variant the model also emits for the same tool (single-quoted list).
    @Test func parsesHyphenatedMCPToolNameWithArrayArg() {
        let calls = LFM2ToolCalls.parse(
            "[parallel-search__web_search(objective='Find a recipe', "
                + "search_queries=['baked potatoes recipe', 'easy baked potatoes', 'classic potato bake'])]"
        )
        #expect(calls.first?.name == "parallel-search__web_search")
        guard case .array(let queries)? = calls.first?.arguments["search_queries"] else {
            Issue.record("search_queries was not an array")
            return
        }
        #expect(queries.count == 3)
        #expect(queries.first == .string("baked potatoes recipe"))
    }

    @Test func parsesMultipleCallsInOneBlock() {
        let calls = LFM2ToolCalls.parse("[current_datetime(), write_clipboard(text='done')]")
        #expect(calls.map(\.name) == ["current_datetime", "write_clipboard"])
        #expect(calls.last?.arguments["text"] == .string("done"))
    }

    @Test func parsesScalarTypes() {
        let calls = LFM2ToolCalls.parse("[t(a=2, b=3.5, c=True, d=False, e=None, f='x')]")
        let args = calls.first?.arguments
        #expect(args?["a"] == .int(2))
        #expect(args?["b"] == .double(3.5))
        #expect(args?["c"] == .bool(true))
        #expect(args?["d"] == .bool(false))
        #expect(args?["e"] == .null)
        #expect(args?["f"] == .string("x"))
    }

    @Test func toleratesUnquotedStringValue() {
        // The model sometimes drops quotes on a plain string; treat it as a string.
        let calls = LFM2ToolCalls.parse("[calculator(expression=2+2)]")
        #expect(calls.first?.arguments["expression"] == .string("2+2"))
    }

    @Test func emptyOrGarbageBlockYieldsNoCalls() {
        #expect(LFM2ToolCalls.parse("").isEmpty)
        #expect(LFM2ToolCalls.parse("[]").isEmpty)
        #expect(LFM2ToolCalls.parse("not a call").isEmpty)
    }

    // MARK: - Streaming splitter

    @Test func stripsToolCallSpanFromVisibleText() {
        var stream = LFM2ToolCallStream()
        let visible =
            stream.consume(
                "<think>I should check.</think><|tool_call_start|>[current_datetime()]"
                    + "<|tool_call_end|>"
            )
        #expect(visible == "<think>I should check.</think>")
        #expect(stream.toolCallBlocks == ["[current_datetime()]"])
        #expect(stream.finish() == "")
    }

    @Test func keepsTextAfterAToolCall() {
        var stream = LFM2ToolCallStream()
        var out = stream.consume("<|tool_call_start|>[a()]<|tool_call_end|>The answer.")
        out += stream.finish()
        #expect(out == "The answer.")
        #expect(stream.toolCallBlocks == ["[a()]"])
    }

    /// Tags arriving split across chunk boundaries must never leak into the visible text.
    @Test func handlesTagsSplitAcrossChunks() {
        var stream = LFM2ToolCallStream()
        var visible = ""
        // Deliberately break the start/end tags mid-way.
        for chunk in ["before <|tool_", "call_start|>[write_clipboard(text='x, y')]<|tool_", "call_end|> after"] {
            visible += stream.consume(chunk)
        }
        visible += stream.finish()
        #expect(visible == "before  after")
        #expect(stream.toolCallBlocks == ["[write_clipboard(text='x, y')]"])

        // And the captured block parses with the comma inside the string intact.
        let calls = LFM2ToolCalls.parse(stream.toolCallBlocks[0])
        #expect(calls.first?.arguments["text"] == .string("x, y"))
    }

    @Test func capturesUnterminatedSpanOnFinish() {
        var stream = LFM2ToolCallStream()
        _ = stream.consume("text <|tool_call_start|>[write_todos(todos=[{'content': 'step")
        _ = stream.finish()
        #expect(stream.toolCallBlocks.count == 1)
        #expect(stream.toolCallBlocks[0].hasPrefix("[write_todos"))
    }

    /// End to end: a realistic round (think + nested-array tool call) splits and parses into
    /// the structured todos the agent needs — exactly the cake flow that used to collapse to
    /// one item.
    @Test func endToEndThinkPlusNestedToolCall() {
        var stream = LFM2ToolCallStream()
        let raw =
            "<think>Plan the cake.</think><|tool_call_start|>[write_todos(todos=["
                + "{'content': 'Gather ingredients', 'status': 'pending'}, "
                + "{'content': 'Mix and bake', 'status': 'pending'}])]<|tool_call_end|>"
        let visible = stream.consume(raw) + stream.finish()
        #expect(visible == "<think>Plan the cake.</think>")

        let calls = stream.toolCallBlocks.flatMap { LFM2ToolCalls.parse($0) }
        #expect(calls.count == 1)
        guard case .array(let items)? = calls.first?.arguments["todos"] else {
            Issue.record("todos not an array")
            return
        }
        #expect(items.count == 2)
    }
}
