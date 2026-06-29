import Foundation

/// Small helpers for pulling typed values out of a tool's `[String: AgentJSON]` arguments.
/// Models emit loose shapes (a number as a string, a bool as `"true"`), so these coerce
/// forgivingly - the same spirit as ``AppleNotesMiddleware``'s `intArgument`.
public enum ToolArgs {
    /// A trimmed, non-empty string for `key`, or nil.
    public static func string(_ args: [String: AgentJSON], _ key: String) -> String? {
        guard case .string(let value)? = args[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The raw string for `key` without trimming or emptiness checks (a regex, a request body).
    public static func rawString(_ args: [String: AgentJSON], _ key: String) -> String? {
        if case .string(let value)? = args[key] { return value }
        return nil
    }

    /// An integer for `key`, accepting an int, a double, or a numeric string.
    public static func int(_ args: [String: AgentJSON], _ key: String) -> Int? {
        switch args[key] {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// A bool for `key`, accepting a bool, `"true"`/`"yes"`/`"1"`, or a non-zero int.
    public static func bool(_ args: [String: AgentJSON], _ key: String) -> Bool {
        switch args[key] {
        case .bool(let value): return value
        case .string(let value): return ["true", "yes", "1"].contains(value.lowercased())
        case .int(let value): return value != 0
        default: return false
        }
    }

    /// A string→string map for `key` (e.g. HTTP headers), coercing scalar values to text.
    public static func stringMap(_ args: [String: AgentJSON], _ key: String) -> [String: String] {
        guard case .object(let object)? = args[key] else { return [:] }
        var result: [String: String] = [:]
        for (name, value) in object { result[name] = scalarString(value) }
        return result
    }

    /// True if `value` would be parsed as a command-line option (begins with `-`). The tools
    /// that shell out reject such values rather than risk an argument being read as a flag.
    public static func looksLikeOption(_ value: String) -> Bool { value.hasPrefix("-") }

    private static func scalarString(_ value: AgentJSON) -> String {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return String(flag)
        default: return ""
        }
    }
}
