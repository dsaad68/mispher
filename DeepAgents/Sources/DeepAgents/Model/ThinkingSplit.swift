import Foundation

/// Splits a model reply into its `<think>` chain-of-thought and final answer. Shared by the UI
/// (reasoning disclosure) and the JSONL message log (separate `content`/`reasoning` fields).
public enum ThinkingSplit {
    /// Extracts *every* `<think>…</think>` block into the reasoning section (joined),
    /// leaving only the non-think text as the answer. The agent's tool loop runs the
    /// model more than once per turn, so a reply can contain several think blocks —
    /// all of them belong in the reasoning disclosure, not the answer body. While
    /// streaming, a trailing unclosed `<think>` is treated as in-progress reasoning.
    public static func split(_ raw: String) -> (thinking: String?, answer: String) {
        var thinkingParts: [String] = []
        var answer = ""
        var remainder = Substring(raw)

        while let open = remainder.range(of: "<think>") {
            answer += String(remainder[..<open.lowerBound])
            let afterOpen = remainder[open.upperBound...]
            if let close = afterOpen.range(of: "</think>") {
                thinkingParts.append(String(afterOpen[..<close.lowerBound]))
                remainder = afterOpen[close.upperBound...]
            } else {
                // Unclosed block (still streaming): everything left is reasoning.
                thinkingParts.append(String(afterOpen))
                remainder = Substring()
                break
            }
        }
        answer += String(remainder)

        let thinking = thinkingParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (
            thinking.isEmpty ? nil : thinking,
            answer.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
