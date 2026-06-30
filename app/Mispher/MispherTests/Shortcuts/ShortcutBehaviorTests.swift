import Foundation
@testable import Mispher
import Testing

/// The pure finish/silence decision helpers that the view model routes through, so the pause-vs-stop
/// and silence-gating rules are pinned independent of the live recording lifecycle.
@MainActor
struct ShortcutBehaviorTests {
    @Test func transcriptionHonorsFinishBehavior() {
        #expect(TranscriptionViewModel.finishAction(intent: .transcription, behavior: .pause) == .pause)
        #expect(TranscriptionViewModel.finishAction(intent: .transcription, behavior: .stop) == .stop)
    }

    @Test func nonTranscriptionAlwaysStops() {
        for intent in [RecordIntent.ask, .rewrite, .translate] {
            #expect(TranscriptionViewModel.finishAction(intent: intent, behavior: .pause) == .stop)
            #expect(TranscriptionViewModel.finishAction(intent: intent, behavior: .stop) == .stop)
        }
    }

    @Test func silenceArmsForTriggerWhenEnabledNeverForHold() {
        #expect(TranscriptionViewModel.shouldArmSilence(enabled: true, mode: .trigger))
        #expect(!TranscriptionViewModel.shouldArmSilence(enabled: true, mode: .hold))
        // Push-to-talk never auto-ends regardless of the toggle.
        #expect(!TranscriptionViewModel.shouldArmSilence(enabled: false, mode: .hold))
    }

    /// Hold & release is hands-free: the silence timeout is its primary stop, so it arms whether or
    /// not the (Trigger-only) "Auto-end on silence" toggle is on.
    @Test func holdReleaseAlwaysArmsSilence() {
        #expect(TranscriptionViewModel.shouldArmSilence(enabled: true, mode: .holdRelease))
        #expect(TranscriptionViewModel.shouldArmSilence(enabled: false, mode: .holdRelease))
    }

    /// With the toggle off, only Hold & release auto-ends; Trigger and push-to-talk do not.
    @Test func disabledToggleArmsOnlyHoldRelease() {
        #expect(!TranscriptionViewModel.shouldArmSilence(enabled: false, mode: .trigger))
        #expect(!TranscriptionViewModel.shouldArmSilence(enabled: false, mode: .hold))
        #expect(TranscriptionViewModel.shouldArmSilence(enabled: false, mode: .holdRelease))
    }
}
