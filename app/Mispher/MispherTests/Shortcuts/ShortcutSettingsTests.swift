import Foundation
@testable import Mispher
import Testing

/// Persistence + migration for the shortcut settings: the one-time hands-free → trigger migration,
/// clamping of the numeric tunings, and the finish-behavior default. Each test uses an isolated
/// `UserDefaults` suite so it never touches the real app domain.
@MainActor
struct ShortcutSettingsTests {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "test.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: loadMode + hands-free migration

    @Test func loadModeDefaultsToHoldWhenUnset() {
        let defaults = freshDefaults("mode-unset")
        #expect(TranscriptionViewModel.loadMode("mode", defaults: defaults) == .hold)
    }

    @Test func loadModeReadsValidValue() {
        let defaults = freshDefaults("mode-valid")
        defaults.set("trigger", forKey: "mode")
        #expect(TranscriptionViewModel.loadMode("mode", defaults: defaults) == .trigger)
    }

    @Test func loadModeUnknownFallsBackToHold() {
        let defaults = freshDefaults("mode-unknown")
        defaults.set("bogus", forKey: "mode")
        #expect(TranscriptionViewModel.loadMode("mode", defaults: defaults) == .hold)
    }

    @Test func loadModeMigratesHandsFreeToTriggerAndEnablesSilence() {
        let defaults = freshDefaults("mode-migrate")
        defaults.set("handsFree", forKey: "mode")

        let migrated = TranscriptionViewModel.loadMode("mode", defaults: defaults)

        #expect(migrated == .trigger)
        // Writes the migrated value back (idempotent on a second load).
        #expect(defaults.string(forKey: "mode") == "trigger")
        #expect(TranscriptionViewModel.loadMode("mode", defaults: defaults) == .trigger)
        // Turns silence auto-end on once so old hands-free users keep auto-finish.
        #expect(defaults.bool(forKey: TranscriptionViewModel.silenceAutoEndEnabledKey))
    }

    @Test func migrationDoesNotOverrideAnExplicitSilencePreference() {
        let defaults = freshDefaults("mode-migrate-respect")
        defaults.set(false, forKey: TranscriptionViewModel.silenceAutoEndEnabledKey)
        defaults.set("handsFree", forKey: "mode")

        _ = TranscriptionViewModel.loadMode("mode", defaults: defaults)

        // Already had an explicit value → migration must not flip it on.
        #expect(defaults.bool(forKey: TranscriptionViewModel.silenceAutoEndEnabledKey) == false)
    }

    // MARK: loadClamped

    @Test func loadClampedReturnsDefaultWhenUnset() {
        let defaults = freshDefaults("clamp-unset")
        #expect(TranscriptionViewModel.loadClamped("k", default: 0.8, min: 0.3, max: 3, defaults: defaults) == 0.8)
    }

    @Test func loadClampedClampsBelowAndAbove() {
        let defaults = freshDefaults("clamp-range")
        defaults.set(-5.0, forKey: "k")
        #expect(TranscriptionViewModel.loadClamped("k", default: 0, min: 0, max: 3, defaults: defaults) == 0)
        defaults.set(99.0, forKey: "k")
        #expect(TranscriptionViewModel.loadClamped("k", default: 0, min: 0, max: 3, defaults: defaults) == 3)
    }

    @Test func loadClampedPassesThroughInRange() {
        let defaults = freshDefaults("clamp-inrange")
        defaults.set(1.6, forKey: "k")
        #expect(TranscriptionViewModel.loadClamped("k", default: 0, min: 1, max: 5, defaults: defaults) == 1.6)
    }

    // MARK: loadFinishBehavior

    @Test func loadFinishBehaviorDefaultsToPause() {
        let defaults = freshDefaults("finish-unset")
        #expect(TranscriptionViewModel.loadFinishBehavior(defaults: defaults) == .pause)
    }

    @Test func loadFinishBehaviorReadsStoredValue() {
        let defaults = freshDefaults("finish-stored")
        defaults.set("stop", forKey: TranscriptionViewModel.transcriptionFinishBehaviorKey)
        #expect(TranscriptionViewModel.loadFinishBehavior(defaults: defaults) == .stop)
    }

    @Test func loadFinishBehaviorInvalidFallsBackToPause() {
        let defaults = freshDefaults("finish-invalid")
        defaults.set("nonsense", forKey: TranscriptionViewModel.transcriptionFinishBehaviorKey)
        #expect(TranscriptionViewModel.loadFinishBehavior(defaults: defaults) == .pause)
    }

    // MARK: Feature master switches (loadBoolDefaultTrue + loadDictationEnabled)

    @Test func loadBoolDefaultTrueDefaultsOnWhenUnset() {
        let defaults = freshDefaults("bool-unset")
        #expect(TranscriptionViewModel.loadBoolDefaultTrue("feature", defaults: defaults))
    }

    @Test func loadBoolDefaultTrueReadsStoredValue() {
        let defaults = freshDefaults("bool-stored")
        defaults.set(false, forKey: "feature")
        #expect(TranscriptionViewModel.loadBoolDefaultTrue("feature", defaults: defaults) == false)
        defaults.set(true, forKey: "feature")
        #expect(TranscriptionViewModel.loadBoolDefaultTrue("feature", defaults: defaults))
    }

    @Test func loadDictationEnabledDefaultsOffWhenUnset() {
        let defaults = freshDefaults("dict-unset")
        #expect(TranscriptionViewModel.loadDictationEnabled(defaults: defaults) == false)
    }

    @Test func loadDictationEnabledMigratesLegacyCleanupValue() {
        let defaults = freshDefaults("dict-migrate")
        defaults.set(true, forKey: TranscriptionViewModel.cleanupWithAIKey)
        // No new key yet → inherit the old "Clean up dictation with AI" choice.
        #expect(TranscriptionViewModel.loadDictationEnabled(defaults: defaults))
    }

    @Test func loadDictationEnabledPrefersNewKeyOverLegacy() {
        let defaults = freshDefaults("dict-newkey")
        defaults.set(true, forKey: TranscriptionViewModel.cleanupWithAIKey)
        defaults.set(false, forKey: TranscriptionViewModel.dictationEnabledKey)
        #expect(TranscriptionViewModel.loadDictationEnabled(defaults: defaults) == false)
    }

    // MARK: Radial picker

    @Test func radialEnabledDefaultsOnForNewAndExistingUsers() {
        let defaults = freshDefaults("radial-unset")
        // The picker is the default launcher, so an unset key reads on (like the other master switches).
        #expect(TranscriptionViewModel.loadBoolDefaultTrue(TranscriptionViewModel.radialEnabledKey, defaults: defaults))
    }

    @Test func radialEnabledReadsStoredOff() {
        let defaults = freshDefaults("radial-off")
        defaults.set(false, forKey: TranscriptionViewModel.radialEnabledKey)
        #expect(TranscriptionViewModel.loadBoolDefaultTrue(TranscriptionViewModel.radialEnabledKey, defaults: defaults) == false)
    }

    @Test func radialLayoutDefaultsThenPersistsEdits() {
        let defaults = freshDefaults("radial-layout")
        #expect(TranscriptionViewModel.loadRadialLayout(defaults: defaults) == .default)
        let edited = RadialLayout.default.assigning(.ask, to: .up)
        TranscriptionViewModel.saveRadialLayout(edited, defaults: defaults)
        #expect(TranscriptionViewModel.loadRadialLayout(defaults: defaults) == edited)
    }

    @Test func radialLayoutSelfHealsFromCorruptStore() {
        let defaults = freshDefaults("radial-layout-corrupt")
        defaults.set(["ask", "ask", "rewrite", "translate"], forKey: TranscriptionViewModel.radialLayoutKey)
        #expect(TranscriptionViewModel.loadRadialLayout(defaults: defaults) == .default)
    }
}
