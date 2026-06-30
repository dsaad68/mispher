import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
@testable import Mispher
import Testing

/// The expanded translation language set and the per-model supported lists used to filter the
/// target-language pickers by the selected Liquid AI LFM2.5 model.
struct TranslationLanguageTests {
    @Test func tenLanguages() {
        #expect(TranslationLanguage.allCases.count == 10)
    }

    @Test func displayNamesAndCodes() {
        #expect(TranslationLanguage.english.displayName == "English")
        #expect(TranslationLanguage.arabic.code == "AR")
        #expect(TranslationLanguage.portuguese.displayName == "Portuguese")
        #expect(TranslationLanguage.italian.code == "IT")
        #expect(TranslationLanguage.spanish.code == "ES")
        #expect(TranslationLanguage.korean.promptName == "Korean")
    }

    @Test func perModelSets() {
        #expect(TranslationLanguage.lfmSmallLanguages.count == 9)
        #expect(!TranslationLanguage.lfmSmallLanguages.contains(.italian))
        #expect(TranslationLanguage.lfmSmallLanguages.contains(.portuguese))

        #expect(TranslationLanguage.lfmMidLanguages.count == 8)
        #expect(!TranslationLanguage.lfmMidLanguages.contains(.italian))
        #expect(!TranslationLanguage.lfmMidLanguages.contains(.portuguese))

        #expect(TranslationLanguage.lfmLargeLanguages.count == 10)
        #expect(Set(TranslationLanguage.lfmLargeLanguages) == Set(TranslationLanguage.allCases))

        // English is always available, whichever model is chosen.
        let sets = [
            TranslationLanguage.lfmSmallLanguages,
            TranslationLanguage.lfmMidLanguages,
            TranslationLanguage.lfmLargeLanguages
        ]
        for set in sets {
            #expect(set.contains(.english))
        }
    }
}

/// Each Liquid AI LFM2.5 catalog model declares exactly the translation languages from its card.
struct MlxModelTranslationLanguageTests {
    private func model(_ id: String) -> MlxModel {
        MlxModel.catalog.first { $0.id == id }!
    }

    @Test func threeFiftyMSupportsNineWithoutItalian() {
        let langs = model("LiquidAI/LFM2.5-350M-MLX-8bit").translationLanguages
        #expect(langs == TranslationLanguage.lfmSmallLanguages)
        #expect(langs.contains(.portuguese))
        #expect(!langs.contains(.italian))
    }

    @Test func oneTwoBSupportsEightWithoutItalianOrPortuguese() {
        for id in [
            "LiquidAI/LFM2.5-1.2B-Instruct-MLX-8bit",
            "LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16",
            "LiquidAI/LFM2.5-1.2B-Thinking-MLX-8bit",
            "LiquidAI/LFM2.5-1.2B-Thinking-MLX-bf16"
        ] {
            let langs = model(id).translationLanguages
            #expect(langs == TranslationLanguage.lfmMidLanguages)
            #expect(!langs.contains(.italian))
            #expect(!langs.contains(.portuguese))
        }
    }

    @Test func eightBSupportsAllTen() {
        #expect(model("LiquidAI/LFM2.5-8B-A1B-MLX-8bit").translationLanguages == TranslationLanguage.lfmLargeLanguages)
    }

    @Test func visionModelsDeclareNoLanguages() {
        for model in MlxModel.catalog where model.isVision {
            #expect(model.translationLanguages.isEmpty)
        }
    }

    @Test func everyTranslationModelOffersEnglish() {
        for model in MlxModel.languageCatalog {
            #expect(!model.translationLanguages.isEmpty)
            #expect(model.translationLanguages.contains(.english))
        }
    }
}
