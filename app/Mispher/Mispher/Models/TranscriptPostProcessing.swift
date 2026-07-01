import Foundation

/// One find→replace rule for the custom dictionary (T2). Each rule maps one or more
/// case-insensitive trigger phrases to a single replacement, applied to the finalized
/// transcript with whole-word matching so only complete words/phrases are replaced.
struct CustomDictionaryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Words/phrases to look for (case-insensitive). Multiple triggers → one replacement.
    var triggers: [String]
    /// The text each trigger is replaced with.
    var replacement: String

    init(id: UUID = UUID(), triggers: [String] = [], replacement: String = "") {
        self.id = id
        self.triggers = triggers
        self.replacement = replacement
    }
}

/// Deterministic, on-device post-processing for finalized transcripts: filler-word
/// removal (T5) and the custom find→replace dictionary (T2). Pure and side-effect free so
/// it runs synchronously in the finalize path and is unit-testable without a model.
enum TranscriptPostProcessing {
    /// Conservative set of standalone hesitation fillers removed by ``stripFillers(_:)``.
    /// Deliberately excludes ambiguous words like "like" / "you know" (too many false
    /// positives); the AI cleanup pass (T3) handles those in context when enabled.
    static let fillerWords = [
        "um", "umm", "uh", "uhh", "uhm", "er", "err", "erm", "ah", "mm", "hmm", "mhm"
    ]

    /// Remove standalone filler words (case-insensitive, whole-word) and tidy the fallout:
    /// drop a comma left dangling by a removed filler, collapse doubled spaces, remove
    /// spaces before punctuation, trim, and re-capitalize the first letter. Best-effort and
    /// conservative — see ``fillerWords``.
    static func stripFillers(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let alternation = fillerWords
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // Consume an optional trailing comma + surrounding spaces so "um, hello" → "hello".
        let pattern = "\\b(?:\(alternation))\\b\\s*,?\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        var result = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        result = tidyWhitespace(result)
        return capitalizingFirstLetter(result)
    }

    /// Apply the custom find→replace dictionary (T2). For each entry, every non-empty
    /// trigger is matched case-insensitively as a whole word and replaced with the entry's
    /// replacement. Trigger and replacement are treated as literal text (regex metacharacters
    /// in both are escaped). Whole-word matching uses word-char lookarounds rather than `\b`
    /// so triggers ending or starting with non-word characters (e.g. "c++", ".net") still match.
    static func applyDictionary(_ text: String, entries: [CustomDictionaryEntry]) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }
        var result = text
        for entry in entries {
            let template = NSRegularExpression.escapedTemplate(for: entry.replacement)
            for trigger in entry.triggers {
                let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let pattern = "(?<!\\w)\(NSRegularExpression.escapedPattern(for: trimmed))(?!\\w)"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    continue
                }
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
            }
        }
        return result
    }

    // MARK: - Helpers

    /// Collapse runs of spaces/tabs, drop spaces before `,.!?;:`, and trim the ends.
    private static func tidyWhitespace(_ text: String) -> String {
        var result = text
        if let spaces = try? NSRegularExpression(pattern: "[ \\t]{2,}") {
            let range = NSRange(result.startIndex..., in: result)
            result = spaces.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
        }
        if let beforePunct = try? NSRegularExpression(pattern: "\\s+([,.!?;:])") {
            let range = NSRange(result.startIndex..., in: result)
            result = beforePunct.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uppercase the first letter, skipping leading punctuation/quotes/emoji so dictation
    /// like `"hello"` still capitalizes the H. Leaves the rest untouched.
    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let idx = text.firstIndex(where: { $0.isLetter }) else { return text }
        return text.replacingCharacters(in: idx ... idx, with: text[idx].uppercased())
    }
}
