import DeepAgents
import Foundation

/// System prompt for Rewrite Mode: the user highlighted some text and spoke an instruction
/// for how to change it. The selected text is embedded here as context; the spoken instruction
/// arrives as the user message. Mirrors ``TranslationPrompt`` / ``CleanupPrompt`` — one fixed,
/// output-only prompt run through a no-tool ``ReactAgent``.
///
/// The instruction block is user-editable in Settings (the Rewrite tab). The user marks where the
/// highlighted text should be dropped in with the ``selectionToken`` placeholder, shown there as a
/// pill; ``system(instructions:selection:)`` substitutes the real selection for it at run time. If
/// the placeholder is missing the selection is appended, so an edit can never strand the input.
enum RewritePrompt {
    /// Placeholder marking where the user's selected text is substituted in. Stored literally in
    /// the saved prompt string; rendered as a pill in the Settings editor.
    static let selectionToken = "{{SELECTION}}"

    /// The default, user-editable instruction block. The selection lands at the ``selectionToken``.
    static let defaultInstructions = """
    You are an inline text editor. Apply the user's instruction to the selected text and output \
    ONLY the rewritten text - no preamble, quotes, explanations, or notes. Preserve meaning and \
    formatting unless the instruction says otherwise.

    SELECTED TEXT:
    \(selectionToken)
    """

    /// Compose the full system prompt: the instruction block (the user's custom text, or the
    /// built-in default when it's blank) with the selected text substituted at the placeholder. If
    /// the placeholder was removed, the selection is appended so the rewrite still has its input.
    static func system(instructions: String, selection: String) -> String {
        let head = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = head.isEmpty ? defaultInstructions : head
        if template.contains(selectionToken) {
            return template.replacingOccurrences(of: selectionToken, with: selection)
        }
        return """
        \(template)

        SELECTED TEXT:
        \(selection)
        """
    }
}
