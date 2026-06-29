import Foundation

/// System prompt for the translation pass. Parameterized by target language so the same
/// text serves any target. Shared by the on-device ``TranslationAgent`` and the llama.cpp
/// server path (`TranslationClient`).
///
/// The instruction block is user-editable in Settings (the Translate tab). The user marks where
/// the target language and the input text appear with the ``languageToken`` / ``inputToken``
/// placeholders, shown there as pills; ``system(instructions:targetLanguage:text:)`` substitutes
/// the real values at run time. The language is appended if its placeholder is missing, so the
/// prompt always names a target.
enum TranslationPrompt {
    /// Placeholder for the target language name (rendered as a pill in the Settings editor).
    static let languageToken = "{{LANGUAGE}}"
    /// Placeholder for the text being translated (rendered as a pill in the Settings editor).
    static let inputToken = "{{INPUT}}"

    /// The default, user-editable instruction block: one target-language reference, one input.
    static let defaultInstructions = """
    You are a translation engine. Translate the input text below into \(languageToken). Output only \
    the translation, with no preamble, quotes, explanations, or notes.

    INPUT TEXT:
    \(inputToken)
    """

    /// Compose the system prompt from the instruction block (the user's custom text, or the
    /// built-in default when it's blank), substituting the target language and the input text at
    /// their placeholders. A missing language placeholder gets a trailing instruction naming it.
    static func system(instructions: String, targetLanguage: String, text: String) -> String {
        let head = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var template = head.isEmpty ? defaultInstructions : head
        if !template.contains(languageToken) {
            template += "\n\nTranslate the text into \(targetLanguage)."
        }
        return template
            .replacingOccurrences(of: languageToken, with: targetLanguage)
            .replacingOccurrences(of: inputToken, with: text)
    }

    /// Back-compat convenience (the default prompt for a target language, no input baked in), used
    /// by the llama.cpp `TranslationClient` path.
    static func system(targetLanguage: String) -> String {
        system(instructions: defaultInstructions, targetLanguage: targetLanguage, text: "")
    }
}
