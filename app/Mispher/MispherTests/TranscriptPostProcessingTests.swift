import Foundation
@testable import Mispher
import Testing

/// Deterministic transcript post-processing: filler-word removal (T5) and the custom
/// find→replace dictionary (T2).
struct TranscriptPostProcessingTests {
    // MARK: - Filler removal (T5)

    @Test func stripsLeadingFillerAndCapitalizes() {
        #expect(TranscriptPostProcessing.stripFillers("um, hello world") == "Hello world")
        #expect(TranscriptPostProcessing.stripFillers("uh hello") == "Hello")
    }

    @Test func stripsMidSentenceFiller() {
        #expect(TranscriptPostProcessing.stripFillers("I think um we should go") == "I think we should go")
    }

    @Test func stripsFillersCaseInsensitively() {
        #expect(TranscriptPostProcessing.stripFillers("Um okay, Uh sure") == "Okay, sure")
    }

    @Test func preservesWordsContainingFillerSubstrings() {
        // "humming" contains "hum" but not the standalone token "hmm" — must be untouched.
        #expect(TranscriptPostProcessing.stripFillers("I was humming") == "I was humming")
        // "summary" contains "um" but is a whole word — must be untouched.
        #expect(TranscriptPostProcessing.stripFillers("the summary") == "The summary")
    }

    @Test func fillerRemovalIsNoOpOnEmpty() {
        #expect(TranscriptPostProcessing.stripFillers("") == "")
    }

    // MARK: - Custom dictionary (T2)

    @Test func replacesWholeWordCaseInsensitively() {
        let entries = [CustomDictionaryEntry(triggers: ["k8s"], replacement: "Kubernetes")]
        #expect(TranscriptPostProcessing.applyDictionary("deploy to K8S now", entries: entries) == "deploy to Kubernetes now")
    }

    @Test func doesNotReplaceSubstrings() {
        let entries = [CustomDictionaryEntry(triggers: ["cat"], replacement: "dog")]
        // "category" must not become "dogegory".
        #expect(TranscriptPostProcessing.applyDictionary("the category of cat", entries: entries) == "the category of dog")
    }

    @Test func supportsMultipleTriggersForOneReplacement() {
        let entries = [CustomDictionaryEntry(triggers: ["misper", "mishfer"], replacement: "Mispher")]
        #expect(TranscriptPostProcessing.applyDictionary("open misper and mishfer", entries: entries) == "open Mispher and Mispher")
    }

    @Test func escapesRegexSpecialCharactersInTrigger() {
        let entries = [CustomDictionaryEntry(triggers: ["c++"], replacement: "C plus plus")]
        // The "+" must be treated literally, not as a regex quantifier.
        #expect(TranscriptPostProcessing.applyDictionary("I code c++", entries: entries) == "I code C plus plus")
    }

    @Test func treatsReplacementAsLiteralText() {
        let entries = [CustomDictionaryEntry(triggers: ["price"], replacement: "$5")]
        // "$5" must appear verbatim, not be interpreted as a regex template reference.
        #expect(TranscriptPostProcessing.applyDictionary("the price", entries: entries) == "the $5")
    }

    @Test func ignoresEmptyTriggers() {
        let entries = [CustomDictionaryEntry(triggers: ["", "  "], replacement: "X")]
        #expect(TranscriptPostProcessing.applyDictionary("nothing changes", entries: entries) == "nothing changes")
    }

    @Test func emptyDictionaryIsNoOp() {
        #expect(TranscriptPostProcessing.applyDictionary("untouched text", entries: []) == "untouched text")
    }
}
