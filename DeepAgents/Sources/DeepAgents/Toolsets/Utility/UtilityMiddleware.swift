import Foundation

/// Utility middleware — a couple of small, always-safe built-in tools: the current
/// date/time and a calculator. No system, network, or file access, so they're safe to
/// expose to any model. Contributes the guidance for both tools, so the usage rules
/// travel with the tools rather than being hardcoded in some agent's prompt.
public struct UtilityMiddleware: AgentMiddleware {
    public init() {}
    public var name: String { "utility" }
    public var tools: [any AgentTool] { [CurrentDateTimeTool(), CalculatorTool()] }

    public func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        let composed = [request.systemPrompt, Self.systemPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return try await handler(request.override(systemPrompt: composed))
    }

    /// Today's DATE is injected into the system prompt by the LFM2.5 chat template
    /// whenever tools are declared (see `LFM2ChatTemplate.canonical`), so only the
    /// current TIME needs the tool — claiming the model doesn't know the date made it
    /// flip-flop between calling the tool and reading the prompt.
    public static let systemPrompt = """
    ## Time and math with `current_datetime` / `calculator`
    Today's date is stated in this prompt, next to your tool list — answer date \
    questions from it directly, no tool needed. You do NOT know the current time or \
    arithmetic results on your own — any such value from memory will be wrong, so call \
    `current_datetime` for the time and `calculator` for arithmetic, even when the \
    user doesn't say to. Never claim you cannot tell the time.
    """
}

/// Report the current local date and time.
public struct CurrentDateTimeTool: AgentTool {
    public init() {}
    public var name: String { "current_datetime" }
    public var description: String {
        "Get the current local date and time. Use this whenever the user asks about the date, the day of the week, or the time."
    }

    public func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        let pretty = formatter.string(from: now)
        let iso = ISO8601DateFormatter().string(from: now)
        return ToolOutput("\(pretty) — time zone \(TimeZone.current.identifier), ISO 8601 \(iso)")
    }
}

/// Evaluate a basic arithmetic expression (`+ - * /` and parentheses).
public struct CalculatorTool: AgentTool {
    public init() {}
    public var name: String { "calculator" }
    public var description: String {
        "Evaluate a basic arithmetic expression with + - * / and parentheses, e.g. \"(12 * 8) + 3\"."
    }

    public var parameters: [ToolParameter] {
        [.required("expression", type: .string, description: "The arithmetic expression to evaluate.")]
    }

    public func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        guard case .string(let expression)? = arguments["expression"] else {
            return ToolOutput("Error: `expression` is required.")
        }
        guard let value = ArithmeticEvaluator.evaluate(expression) else {
            return ToolOutput(
                "Error: couldn't evaluate \"\(expression)\". Use only numbers and + - * / ( )."
            )
        }
        // Render whole numbers without a trailing ".0".
        if value == value.rounded(), abs(value) < 1e15 {
            return ToolOutput(String(Int64(value)))
        }
        return ToolOutput(String(value))
    }
}

/// A small, crash-safe recursive-descent evaluator for `+ - * / ( )` over decimal
/// numbers. Returns `nil` on any malformed input and never raises — unlike
/// `NSExpression`, which throws uncatchable Objective-C exceptions on bad input.
public enum ArithmeticEvaluator {
    static func evaluate(_ input: String) -> Double? {
        var parser = Parser(input)
        guard let value = parser.parseExpression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0

        init(_ input: String) { characters = Array(input) }

        var atEnd: Bool {
            peek() == nil
        }

        /// The next non-space character without consuming it.
        private func peek() -> Character? {
            var i = index
            while i < characters.count, characters[i] == " " || characters[i] == "\t" { i += 1 }
            return i < characters.count ? characters[i] : nil
        }

        /// Advance past any spaces and then one character.
        private mutating func consume() {
            while index < characters.count, characters[index] == " " || characters[index] == "\t" {
                index += 1
            }
            if index < characters.count { index += 1 }
        }

        // expression := term (('+' | '-') term)*
        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                consume()
                guard let rhs = parseTerm() else { return nil }
                value = (op == "+") ? value + rhs : value - rhs
            }
            return value
        }

        // term := factor (('*' | '/') factor)*
        private mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                consume()
                guard let rhs = parseFactor() else { return nil }
                if op == "/" {
                    guard rhs != 0 else { return nil }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        // factor := ('+' | '-') factor | '(' expression ')' | number
        private mutating func parseFactor() -> Double? {
            guard let c = peek() else { return nil }
            if c == "+" { consume(); return parseFactor() }
            if c == "-" { consume(); return parseFactor().map { -$0 } }
            if c == "(" {
                consume()
                guard let value = parseExpression(), peek() == ")" else { return nil }
                consume()
                return value
            }
            return parseNumber()
        }

        private mutating func parseNumber() -> Double? {
            // Move to the first non-space character.
            while index < characters.count, characters[index] == " " || characters[index] == "\t" {
                index += 1
            }
            var digits = ""
            while index < characters.count, characters[index].isNumber || characters[index] == "." {
                digits.append(characters[index])
                index += 1
            }
            return digits.isEmpty ? nil : Double(digits)
        }
    }
}
