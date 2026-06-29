import DeepAgents
import Foundation

// LFM2/LFM2.5 emit tool calls as `<|tool_call_start|>[name(arg=value, …)]<|tool_call_end|>`
// with Pythonic argument literals. mlx-swift-lm's built-in `PythonicToolCallParser`
// truncates any list/dict argument at the first comma — its unquoted-value regex is
// `[^,)]+` — so `write_todos(todos=[{…}, {…}])` loses everything after the first comma and
// the array collapses to one garbage item. The model actually emits the right structure;
// only the parse is wrong. So we parse these calls ourselves: generation runs with the
// built-in detection suppressed (a non-matching `toolCallFormat`), `LFM2ToolCallStream`
// strips the tag spans from the visible text, and `LFM2ToolCalls.parse` does a bracket- and
// quote-aware parse that preserves nested arrays/objects.

/// Splits a streaming generation into visible text and the raw inner text of each
/// `<|tool_call_start|>…<|tool_call_end|>` span, holding back partial tags across chunk
/// boundaries so a tag split over two chunks is never shown to the user.
public struct LFM2ToolCallStream {
    static let startTag = "<|tool_call_start|>"
    static let endTag = "<|tool_call_end|>"

    private var buffer = ""
    private var inCall = false
    private var callBuffer = ""
    /// The raw inner text of each completed tool-call span, in order.
    private(set) var toolCallBlocks: [String] = []

    /// Feed a chunk of generated text; returns the portion that is safe to show now (with
    /// tool-call spans removed).
    mutating func consume(_ chunk: String) -> String {
        buffer += chunk
        var visible = ""
        while true {
            if !inCall {
                if let range = buffer.range(of: Self.startTag) {
                    visible += buffer[..<range.lowerBound]
                    buffer = String(buffer[range.upperBound...])
                    inCall = true
                } else {
                    let cut = Self.safeEmitEnd(of: buffer, tag: Self.startTag)
                    visible += buffer[..<cut]
                    buffer = String(buffer[cut...])
                    break
                }
            } else {
                if let range = buffer.range(of: Self.endTag) {
                    callBuffer += buffer[..<range.lowerBound]
                    toolCallBlocks.append(callBuffer)
                    callBuffer = ""
                    buffer = String(buffer[range.upperBound...])
                    inCall = false
                } else {
                    let cut = Self.safeEmitEnd(of: buffer, tag: Self.endTag)
                    callBuffer += buffer[..<cut]
                    buffer = String(buffer[cut...])
                    break
                }
            }
        }
        return visible
    }

    /// Flush any trailing text once the stream ends; returns remaining visible text. A span
    /// left unterminated (the model stopped mid-call) is still captured, best-effort.
    mutating func finish() -> String {
        defer { buffer = ""; callBuffer = ""; inCall = false }
        if inCall {
            callBuffer += buffer
            if !callBuffer.isEmpty { toolCallBlocks.append(callBuffer) }
            return ""
        }
        return buffer
    }

    /// The index up to which `s` can be emitted without splitting a possible `tag`: holds
    /// back the longest suffix of `s` that is a proper prefix of `tag`.
    private static func safeEmitEnd(of s: String, tag: String) -> String.Index {
        let maxHold = min(s.count, tag.count - 1)
        if maxHold > 0 {
            for hold in stride(from: maxHold, through: 1, by: -1) where tag.hasPrefix(s.suffix(hold)) {
                return s.index(s.endIndex, offsetBy: -hold)
            }
        }
        return s.endIndex
    }
}

/// Parses the inner text of an LFM2 tool-call span — a Pythonic list of calls,
/// `[name(arg=value, …), …]` — into structured `AgentToolCall`s, preserving nested array
/// and object arguments (the thing the built-in parser truncates).
public enum LFM2ToolCalls {
    static func parse(_ block: String) -> [AgentToolCall] {
        var parser = Parser(block)
        return parser.parseCalls()
    }

    private struct Parser {
        private let chars: [Character]
        private var i = 0

        init(_ s: String) { chars = Array(s) }

        private var done: Bool { i >= chars.count }
        private func peek() -> Character? { i < chars.count ? chars[i] : nil }
        private mutating func advance() -> Character { defer { i += 1 }; return chars[i] }
        private mutating func skipWS() { while i < chars.count, chars[i].isWhitespace { i += 1 } }
        private mutating func match(_ c: Character) -> Bool {
            skipWS()
            if peek() == c {
                i += 1
                return true
            }
            return false
        }

        mutating func parseCalls() -> [AgentToolCall] {
            var calls: [AgentToolCall] = []
            skipWS()
            _ = match("[")
            while true {
                skipWS()
                if done || peek() == "]" { break }
                guard let call = parseCall() else { break }
                calls.append(call)
                skipWS()
                _ = match(",")
            }
            return calls
        }

        private mutating func parseCall() -> AgentToolCall? {
            let name = parseIdentifier()
            guard !name.isEmpty, match("(") else { return nil }
            let arguments = parseArguments()
            _ = match(")")
            return AgentToolCall(name: name, arguments: arguments)
        }

        private mutating func parseIdentifier() -> String {
            skipWS()
            var s = ""
            // Hyphens are valid in tool names: MCP tools are namespaced `server__tool` and both
            // halves are sanitized to `[A-Za-z0-9_-]`, so a server like "parallel-search" yields
            // `parallel-search__web_search`. Without `-` here, parseIdentifier stopped at the
            // hyphen, the following `match("(")` failed, and the whole call parsed to nothing -
            // flagged "malformed" and retried forever, so MCP tools with hyphens never ran.
            while let c = peek(), c.isLetter || c.isNumber || c == "_" || c == "-" { s.append(advance()) }
            return s
        }

        private mutating func parseArguments() -> [String: AgentJSON] {
            var arguments: [String: AgentJSON] = [:]
            while true {
                skipWS()
                if done || peek() == ")" { break }
                let key = parseIdentifier()
                guard !key.isEmpty, match("=") else { break }
                arguments[key] = parseValue()
                skipWS()
                if !match(",") { break }
            }
            return arguments
        }

        private mutating func parseValue() -> AgentJSON {
            skipWS()
            switch peek() {
            case "'", "\"": return .string(parseQuoted())
            case "[": return parseArray()
            case "{": return parseObject()
            default: return parseScalar()
            }
        }

        private mutating func parseQuoted() -> String {
            let quote = advance() // opening quote
            var s = ""
            while let c = peek() {
                i += 1
                if c == "\\", let next = peek() {
                    i += 1
                    switch next {
                    case "n": s.append("\n")
                    case "t": s.append("\t")
                    case "r": s.append("\r")
                    default: s.append(next) // \' \" \\ and anything else → literal
                    }
                } else if c == quote {
                    break
                } else {
                    s.append(c)
                }
            }
            return s
        }

        private mutating func parseArray() -> AgentJSON {
            _ = match("[")
            var items: [AgentJSON] = []
            while true {
                skipWS()
                if done || peek() == "]" { break }
                items.append(parseValue())
                skipWS()
                _ = match(",")
            }
            _ = match("]")
            return .array(items)
        }

        private mutating func parseObject() -> AgentJSON {
            _ = match("{")
            var object: [String: AgentJSON] = [:]
            while true {
                skipWS()
                if done || peek() == "}" { break }
                let key = (peek() == "'" || peek() == "\"") ? parseQuoted() : parseIdentifier()
                guard match(":") else { break }
                object[key] = parseValue()
                skipWS()
                _ = match(",")
            }
            _ = match("}")
            return .object(object)
        }

        /// A bare token (number, bool, None, or unquoted word) up to the next delimiter.
        private mutating func parseScalar() -> AgentJSON {
            skipWS()
            var s = ""
            while let c = peek(), c != ",", c != ")", c != "]", c != "}" { s.append(advance()) }
            let token = s.trimmingCharacters(in: .whitespaces)
            switch token {
            case "True", "true": return .bool(true)
            case "False", "false": return .bool(false)
            case "None", "null", "": return .null
            default:
                if let int = Int(token) { return .int(int) }
                if let double = Double(token) { return .double(double) }
                return .string(token)
            }
        }
    }
}
