import DeepAgents
import DeepAgentsMLX
import Foundation

/// A target language the finished transcript can be translated into. The set spans the languages
/// the Liquid AI LFM2.5 models handle; which ones are actually offered is filtered per model (see
/// ``MlxModel/translationLanguages``). Trivially extensible: add a case here and update the
/// per-model sets below.
enum TranslationLanguage: String, CaseIterable, Identifiable, Sendable {
    case english, arabic, chinese, french, german, italian, japanese, korean, portuguese, spanish

    var id: String { rawValue }

    /// Full name, used in menus and the transcript divider.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .arabic: return "Arabic"
        case .chinese: return "Chinese"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .portuguese: return "Portuguese"
        case .spanish: return "Spanish"
        }
    }

    /// Two-letter code for the compact header pill.
    var code: String {
        switch self {
        case .english: return "EN"
        case .arabic: return "AR"
        case .chinese: return "ZH"
        case .french: return "FR"
        case .german: return "DE"
        case .italian: return "IT"
        case .japanese: return "JA"
        case .korean: return "KO"
        case .portuguese: return "PT"
        case .spanish: return "ES"
        }
    }

    /// The language name used in the translation system prompt.
    var promptName: String { displayName }

    // MARK: - Per-model supported sets (Liquid AI LFM2.5 family)

    /// LFM2.5 350M: every language except Italian.
    static let lfmSmallLanguages: [TranslationLanguage] =
        [.english, .arabic, .chinese, .french, .german, .japanese, .korean, .portuguese, .spanish]
    /// LFM2.5 1.2B (Instruct + Thinking): no Italian, no Portuguese.
    static let lfmMidLanguages: [TranslationLanguage] =
        [.english, .arabic, .chinese, .french, .german, .japanese, .korean, .spanish]
    /// LFM2.5 8B-A1B: the full set.
    static let lfmLargeLanguages: [TranslationLanguage] =
        [.english, .arabic, .chinese, .french, .german, .italian, .japanese, .korean, .portuguese, .spanish]
}

extension MlxModel {
    /// The translation target languages this model supports, per Liquid's model cards. Empty for
    /// vision models (translation never runs on a VLM) and any unrecognised model -- callers fall
    /// back to offering all languages in that case.
    var translationLanguages: [TranslationLanguage] {
        guard !isVision else { return [] }
        if id.contains("LFM2.5-8B") { return TranslationLanguage.lfmLargeLanguages }
        if id.contains("LFM2.5-350M") { return TranslationLanguage.lfmSmallLanguages }
        if id.contains("LFM2.5-1.2B") { return TranslationLanguage.lfmMidLanguages }
        return []
    }
}
