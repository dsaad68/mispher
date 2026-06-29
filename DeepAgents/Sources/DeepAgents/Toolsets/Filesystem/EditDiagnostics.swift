import Foundation

/// Why an exact `edit_file` match failed, explained for the model. Pure string analysis (no
/// I/O), so it is trivially testable and never mutates content - the edit stays exact-only,
/// these helpers only describe near-misses so the model can re-copy precisely on its next turn.
///
/// `diagnose` returns the single most-likely cause (checked most-specific first, first hit
/// wins) plus a one-line fix, keeping the tool error short. The other helpers map matches to
/// 1-based line numbers so errors can point at *where*.
enum EditDiagnostics {
    /// The 1-based start line of every non-overlapping exact occurrence of `old` in `content`
    /// (left to right, matching `replacingOccurrences`/`components(separatedBy:)` semantics).
    static func occurrenceLines(_ content: String, _ old: String) -> [Int] {
        guard !old.isEmpty else { return [] }
        var lines: [Int] = []
        var from = content.startIndex
        while let range = content.range(of: old, range: from ..< content.endIndex) {
            lines.append(lineNumber(of: range.lowerBound, in: content))
            from = range.upperBound
        }
        return lines
    }

    /// A short hint explaining why exact matching `old` against `content` found nothing, and
    /// how to fix it. Always returns something (a generic re-copy tip is the fallback).
    static func diagnose(content: String, old: String) -> String {
        // CRLF vs LF: invisible and the model can't easily reproduce it - flag it first.
        if content.contains("\r\n"), !old.contains("\r\n") {
            let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            if let range = normalized.range(of: old) {
                let line = lineNumber(of: range.lowerBound, in: normalized)
                return "The file uses Windows (CRLF) line endings but your old_string uses LF; "
                    + "match the file's line endings (near line \(line))."
            }
        }
        // Trailing whitespace only (leading whitespace still matches) - the zero-risk, common case.
        let trimmedContent = stripPerLine(content, leading: false, trailing: true)
        let trimmedOld = stripPerLine(old, leading: false, trailing: true)
        if !trimmedOld.isEmpty, let range = trimmedContent.range(of: trimmedOld) {
            let line = lineNumber(of: range.lowerBound, in: trimmedContent)
            return "It matches if trailing whitespace is ignored (near line \(line)); "
                + "re-copy the exact text from read_file, including any trailing spaces."
        }
        // Indentation (leading whitespace) differs - point at the line and ask for exact tabs/spaces.
        let dedentedContent = stripPerLine(content, leading: true, trailing: true)
        let dedentedOld = stripPerLine(old, leading: true, trailing: true)
        if !dedentedOld.isEmpty, let range = dedentedContent.range(of: dedentedOld) {
            let line = lineNumber(of: range.lowerBound, in: dedentedContent)
            return "Found at line \(line) if leading indentation is ignored; "
                + "re-copy old_string with the file's exact indentation (tabs vs spaces)."
        }
        // Typographic characters: smart quotes / non-breaking spaces the model emitted by mistake.
        let asciiOld = normalizeTypography(old)
        if asciiOld != old {
            let asciiContent = normalizeTypography(content)
            if let range = asciiContent.range(of: asciiOld) {
                let line = lineNumber(of: range.lowerBound, in: asciiContent)
                return "Your old_string uses smart quotes or non-breaking spaces; the file uses "
                    + "plain ASCII (near line \(line)) - re-copy the exact characters."
            }
        }
        // Nearest anchor: the first non-blank line matches, so orient the model to roughly where.
        if let anchor = old.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           let range = content.range(of: anchor) {
            let line = lineNumber(of: range.lowerBound, in: content)
            return "No full match. The first line of your old_string appears near line \(line) "
                + "but the rest of the block differs - re-read and copy the exact text."
        }
        return "Re-read the file with read_file and copy the exact text to replace, including whitespace and indentation."
    }

    // MARK: - Pure helpers

    /// The 1-based line of `index` in `content` (line 1 = before the first newline).
    static func lineNumber(of index: String.Index, in content: String) -> Int {
        1 + content[content.startIndex ..< index].lazy.filter { $0 == "\n" }.count
    }

    /// `text` with leading and/or trailing spaces/tabs stripped from each line; line count
    /// (and therefore line numbers) is preserved because newlines are kept.
    private static func stripPerLine(_ text: String, leading: Bool, trailing: Bool) -> String {
        text.components(separatedBy: "\n").map { line in
            var slice = Substring(line)
            if leading { while let first = slice.first, first == " " || first == "\t" { slice = slice.dropFirst() } }
            if trailing { while let last = slice.last, last == " " || last == "\t" { slice = slice.dropLast() } }
            return String(slice)
        }.joined(separator: "\n")
    }

    /// Curly quotes → straight quotes and non-breaking spaces → spaces; everything else untouched.
    private static func normalizeTypography(_ text: String) -> String {
        let map: [Character: Character] = [
            "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"", "\u{00A0}": " "
        ]
        return String(text.map { map[$0] ?? $0 })
    }
}
