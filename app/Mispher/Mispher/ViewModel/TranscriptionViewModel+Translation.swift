import DeepAgentsMLX
import Foundation

/// The post-recording translation passes, split out of ``TranscriptionViewModel`` so the main
/// file stays within the length limit. ``translateFinal()`` powers the header Translate toggle
/// (translate the transcription and show it beneath the original); ``translateAndInsert()`` powers
/// the dedicated Translate shortcut (translate and type the result into the focused field).
@MainActor
extension TranscriptionViewModel {
    /// Load the persisted translation prompt, upgrading legacy values once. Prompts saved before
    /// the input-text pill existed lack `{{INPUT}}`; snap those (and any with no saved value) to the
    /// new default so the INPUT TEXT section appears, and persist it. Runs once, then the user's
    /// prompt is left alone.
    static func loadTranslationPrompt() -> String {
        let stored = UserDefaults.standard.string(forKey: translationPromptKey)
        if !UserDefaults.standard.bool(forKey: translationPromptInputMigratedKey) {
            UserDefaults.standard.set(true, forKey: translationPromptInputMigratedKey)
            if stored == nil || stored?.contains(TranslationPrompt.inputToken) == false {
                UserDefaults.standard.set(TranslationPrompt.defaultInstructions, forKey: translationPromptKey)
                return TranslationPrompt.defaultInstructions
            }
        }
        return stored ?? TranslationPrompt.defaultInstructions
    }

    /// Whether translation is on, migrating the legacy Translate→English toggle the
    /// first time the new key is absent.
    static func loadTranslationEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: translationEnabledKey) != nil {
            return defaults.bool(forKey: translationEnabledKey)
        }
        return defaults.bool(forKey: legacyTranslateEnabledKey)
    }

    static func loadTranslationLanguage() -> TranslationLanguage {
        let raw = UserDefaults.standard.string(forKey: translationTargetKey)
        return raw.flatMap(TranslationLanguage.init(rawValue:)) ?? .english
    }

    /// The target languages offered for translation: the selected model's supported set, or every
    /// language when the model declares none (an unknown/custom model).
    var translationLanguages: [TranslationLanguage] {
        let supported = translationModel?.translationLanguages ?? []
        return supported.isEmpty ? TranslationLanguage.allCases : supported
    }

    /// Translate the finalized transcript into the target language on-device with the
    /// chosen instruct model and show it beneath the original. Best-effort: failures
    /// surface as a status hint and leave the original transcript intact.
    func translateFinal() async {
        let source = finalText
        guard !source.isEmpty, let mlx = mlxModels else { return }
        let target = translationTargetLanguage
        let modelId = translationModelId

        isTranslating = true
        statusMessage = "Translating to \(target.displayName)…"
        defer { isTranslating = false }

        let translated = await mlx.translate(
            source, prompt: translationPrompt, modelId: modelId, targetLanguage: target.promptName
        )

        // A new session may have started while we were waiting — don't clobber it.
        guard finalText == source, !isSessionActive else { return }
        if let translated, !translated.isEmpty {
            translatedText = translated
            statusMessage = selectedModel.readyMessage
        } else {
            statusMessage = "Translation unavailable - couldn't run the on-device model."
        }
    }

    /// Translate-intent finalize: translate the spoken transcript into the target language
    /// on-device, then insert the translation into the field captured when recording began (like
    /// dictation). Best-effort: with no model, or on a failed/empty translation, the original
    /// transcript is inserted instead so the user is never left empty-handed.
    func translateAndInsert() async {
        let source = finalText
        guard !source.isEmpty else { return }
        guard let mlx = mlxModels else { finishDictationInsert(source); return }
        let target = translationTargetLanguage

        // Set synchronously (stop() calls this right after state = .idle, before any await) so the
        // compact overlay stays up continuously through the pass -- see ``runRewrite``.
        isTranslating = true
        statusMessage = "Translating to \(target.displayName)…"
        let translated = await mlx.translate(
            source, prompt: translationPrompt, modelId: translationModelId, targetLanguage: target.promptName
        )
        isTranslating = false

        // A new session may have started while we waited — don't insert into it.
        guard state == .idle, activeIntent == .translate else { return }
        let succeeded = !(translated ?? "").isEmpty
        let output = succeeded ? translated! : source
        translatedText = output
        if autoCopyOnFinish { writeToPasteboard(output); flashCopied() }
        finishDictationInsert(output)
        statusMessage = succeeded
            ? selectedModel.readyMessage
            : "Translation unavailable - inserted the original instead."
    }
}
