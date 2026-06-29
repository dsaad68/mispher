import Foundation

/// `UserDefaults`-backed persistence for the view model's custom dictionary. Split out of
/// ``TranscriptionViewModel`` so the main file stays within the length limit. The shortcut,
/// activation-mode, recording-presentation, and MCP-server codecs live alongside the rest of the
/// shortcut handling in ``TranscriptionViewModel`` (see `+ShortcutSupport`).
extension TranscriptionViewModel {
    // MARK: - Custom dictionary persistence

    static func loadCustomDictionary() -> [CustomDictionaryEntry] {
        guard let data = UserDefaults.standard.data(forKey: customDictionaryKey) else { return [] }
        return (try? JSONDecoder().decode([CustomDictionaryEntry].self, from: data)) ?? []
    }

    static func saveCustomDictionary(_ entries: [CustomDictionaryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: customDictionaryKey)
        }
    }

    // MARK: - Dictation cleanup prompt

    /// The persisted, user-editable cleanup instruction block, falling back to the built-in default.
    static func loadCleanupPrompt() -> String {
        UserDefaults.standard.string(forKey: cleanupPromptKey) ?? CleanupPrompt.defaultInstructions
    }

    // MARK: - Selected ASR model

    static func loadSelectedModel() -> AsrModel {
        let raw = UserDefaults.standard.string(forKey: selectedModelKey)
        return raw.flatMap(AsrModel.init(rawValue:)) ?? .parakeetEouEnglish
    }
}
