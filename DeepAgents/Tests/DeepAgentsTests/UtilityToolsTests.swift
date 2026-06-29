@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import MLXLMCommon
import Testing

/// The built-in utility tools: the calculator (and its crash-safe evaluator) and the
/// current date/time tool.
struct UtilityToolsTests {
    @Test func calculatorEvaluatesExpressions() async throws {
        let cases: [(expression: String, expected: String)] = [
            ("(12 * 8) + 3", "99"),
            ("2 + 2", "4"),
            ("10 / 4", "2.5"),
            ("-3 + 5", "2"),
            ("3 * (4 + 5)", "27"),
            ("100 - 1", "99")
        ]
        for testCase in cases {
            let output = try await CalculatorTool()
                .execute(["expression": .string(testCase.expression)], ToolContext())
            #expect(output.content == testCase.expected)
        }
    }

    @Test func calculatorRejectsMalformedInput() async throws {
        for bad in ["", "2 +", "abc", "1 / 0", "(1 + 2", "2 3", "* 5"] {
            let output = try await CalculatorTool().execute(["expression": .string(bad)], ToolContext())
            #expect(output.content.contains("Error"))
        }
    }

    @Test func calculatorRequiresExpression() async throws {
        let output = try await CalculatorTool().execute([:], ToolContext())
        #expect(output.content.contains("Error"))
    }

    @Test func arithmeticEvaluatorRespectsPrecedenceAndSafety() {
        #expect(ArithmeticEvaluator.evaluate("1 + 2 * 3") == 7)
        #expect(ArithmeticEvaluator.evaluate("(1 + 2) * 3") == 9)
        #expect(ArithmeticEvaluator.evaluate("2 * -4") == -8)
        #expect(ArithmeticEvaluator.evaluate("bogus") == nil)
        #expect(ArithmeticEvaluator.evaluate("4 / 0") == nil)
        #expect(ArithmeticEvaluator.evaluate("") == nil)
    }

    @Test func currentDateTimeReportsTime() async throws {
        let output = try await CurrentDateTimeTool().execute([:], ToolContext())
        #expect(!output.content.isEmpty)
        #expect(output.content.contains("ISO 8601"))
    }

    @Test func calculatorHandlesDecimalsAndDeepNesting() async throws {
        let cases: [(expression: String, expected: String)] = [
            ("2.5 * 4", "10"),
            ("((1 + 2) * (3 + 4))", "21"),
            ("7 / 2", "3.5"),
            ("1 - 2 - 3", "-4"),
            ("2 * 3 + 4 * 5", "26")
        ]
        for testCase in cases {
            let output = try await CalculatorTool()
                .execute(["expression": .string(testCase.expression)], ToolContext())
            #expect(output.content == testCase.expected)
        }
    }

    @Test func currentDateTimeTakesNoParameters() {
        let required = CurrentDateTimeTool().toolSchema()["function"]
            .flatMap { ($0 as? [String: any Sendable])?["parameters"] }
            .flatMap { ($0 as? [String: any Sendable])?["required"] as? [String] }
        #expect(required?.isEmpty == true)
    }
}
