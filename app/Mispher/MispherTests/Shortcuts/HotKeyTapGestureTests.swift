import Carbon.HIToolbox
import Foundation
@testable import Mispher
import Testing

/// One emitted gesture: an intent phase, the Stop callback, or a radial-picker event.
private enum GestureEvent: Equatable {
    case intent(RecordIntent, HotKeyTap.Phase)
    case stop
    case radialOpen
    case radialClose
    case radialCancel
    case radialArrow(RadialDirection)
}

/// Records the gestures `HotKeyTap` emits, and answers `isSessionActive`.
@MainActor
private final class GestureRecorder {
    var events: [GestureEvent] = []
    var sessionActive = false
}

/// A `GestureScheduler` that collects scheduled work instead of sleeping, so tests fire the
/// modifier debounce / start-delay / long-press timers deterministically. An early release (which
/// bumps the engine's internal token) is exercised by feeding the release event, then `fireAll()`:
/// the timer closure's own guard swallows it.
@MainActor
private final class ManualGestureScheduler: GestureScheduler {
    private var pending: [@MainActor () -> Void] = []
    var count: Int { pending.count }

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        pending.append(work)
    }

    /// Fire (and clear) every currently-pending timer. Timers scheduled *during* a fire stay queued
    /// for the next `fireAll()` -- mirroring the real two-stage debounce → duration sequence.
    func fireAll() {
        let items = pending
        pending = []
        for work in items { work() }
    }
}

/// The `HotKeyTap` gesture state machine across all three activation modes, driven through synthetic
/// `handleFlags` / `handleKeyDown` / `handleKeyUp` events with a manual scheduler.
@MainActor
struct HotKeyTapGestureTests {
    private func config(
        transcription: Hotkey = .transcriptionDefault,
        transcriptionMode: ActivationMode,
        ask: Hotkey = .askDefault,
        askMode: ActivationMode = .hold,
        startDelay: TimeInterval = 0,
        holdDuration: TimeInterval = 0.8
    ) -> HotKeyTap.Config {
        HotKeyTap.Config(
            transcription: transcription, ask: ask, stop: .stopDefault,
            rewrite: .rewriteDefault, translate: .translateDefault,
            transcriptionMode: transcriptionMode, askMode: askMode, rewriteMode: .hold, translateMode: .hold,
            pushToTalkStartDelay: startDelay, holdReleaseDuration: holdDuration
        )
    }

    private func makeTap(_ cfg: HotKeyTap.Config, _ scheduler: ManualGestureScheduler) -> (HotKeyTap, GestureRecorder) {
        let tap = HotKeyTap(scheduler: scheduler)
        let rec = GestureRecorder()
        tap.wire(
            config: cfg,
            onIntent: { intent, phase in rec.events.append(.intent(intent, phase)) },
            onStop: { rec.events.append(.stop) },
            isSessionActive: { rec.sessionActive },
            onRadialOpen: { rec.events.append(.radialOpen) },
            onRadialClose: { rec.events.append(.radialClose) },
            onRadialCancel: { rec.events.append(.radialCancel) },
            onRadialArrow: { rec.events.append(.radialArrow($0)) }
        )
        return (tap, rec)
    }

    /// A config with the radial picker on (trigger = the given chord, default left ⌥). The per-mode
    /// chords stand down while it's enabled.
    private func radialConfig(radial: Hotkey = .radialDefault, openDelay: TimeInterval = 0.3) -> HotKeyTap.Config {
        HotKeyTap.Config(
            transcription: .transcriptionDefault, ask: .askDefault, stop: .stopDefault,
            rewrite: .rewriteDefault, translate: .translateDefault,
            transcriptionMode: .hold, askMode: .hold, rewriteMode: .hold, translateMode: .hold,
            radial: radial, radialEnabled: true, radialOpenDelay: openDelay
        )
    }

    // MARK: Push to talk (hold)

    @Test func pushToTalkModifierChordPressesThenReleases() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .hold), sched)
        tap.handleFlags([.leftOption])
        sched.fireAll() // debounce → start delay 0 → press immediately
        #expect(rec.events == [.intent(.transcription, .press)])
        tap.handleFlags([]) // release
        #expect(rec.events == [.intent(.transcription, .press), .intent(.transcription, .release)])
    }

    @Test func pushToTalkStartDelayCancelsWhenReleasedEarly() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .hold, startDelay: 2), sched)
        tap.handleFlags([.leftOption])
        sched.fireAll() // debounce → schedules the 2s start-delay timer
        #expect(rec.events.isEmpty)
        #expect(sched.count == 1)
        tap.handleFlags([]) // released before the delay → cancel
        sched.fireAll() // the stale start-delay timer fires but its guard swallows it
        #expect(rec.events.isEmpty)
    }

    @Test func pushToTalkStartDelayPressesWhenHeldThroughout() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .hold, startDelay: 2), sched)
        tap.handleFlags([.leftOption])
        sched.fireAll() // debounce → schedules start delay
        sched.fireAll() // start delay elapses, still held → press
        #expect(rec.events == [.intent(.transcription, .press)])
    }

    @Test func pushToTalkKeyChordDelayCancelsOnEarlyKeyUp() {
        let space = Hotkey(keyCode: UInt16(kVK_Space), modifiers: [.leftOption], keyLabel: "Space")
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcription: space, transcriptionMode: .hold, startDelay: 2), sched)
        _ = tap.handleKeyDown(keyCode: UInt16(kVK_Space), sides: [.leftOption])
        #expect(rec.events.isEmpty)
        tap.handleKeyUp(keyCode: UInt16(kVK_Space)) // released before the delay
        sched.fireAll()
        #expect(rec.events.isEmpty)
        // Held to completion this time.
        _ = tap.handleKeyDown(keyCode: UInt16(kVK_Space), sides: [.leftOption])
        sched.fireAll()
        #expect(rec.events == [.intent(.transcription, .press)])
        tap.handleKeyUp(keyCode: UInt16(kVK_Space))
        #expect(rec.events == [.intent(.transcription, .press), .intent(.transcription, .release)])
    }

    // MARK: Trigger

    @Test func triggerModifierChordTapsOnFullRelease() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .trigger), sched)
        tap.handleFlags([.leftOption]) // marks a trigger candidate, no timer
        #expect(rec.events.isEmpty)
        tap.handleFlags([]) // full release resolves the tap
        #expect(rec.events == [.intent(.transcription, .tap)])
    }

    @Test func triggerKeyChordTapsImmediately() {
        let space = Hotkey(keyCode: UInt16(kVK_Space), modifiers: [.leftOption], keyLabel: "Space")
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcription: space, transcriptionMode: .trigger), sched)
        _ = tap.handleKeyDown(keyCode: UInt16(kVK_Space), sides: [.leftOption])
        #expect(rec.events == [.intent(.transcription, .tap)])
    }

    // MARK: Hold & release

    @Test func holdReleaseTapsAfterLongPress() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .holdRelease), sched)
        tap.handleFlags([.leftOption])
        sched.fireAll() // debounce → schedules long-press
        #expect(rec.events.isEmpty)
        sched.fireAll() // long-press elapses, still held → tap (toggles on)
        #expect(rec.events == [.intent(.transcription, .tap)])
    }

    @Test func holdReleaseCancelsWhenReleasedEarly() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .holdRelease), sched)
        tap.handleFlags([.leftOption])
        sched.fireAll() // schedules long-press
        tap.handleFlags([]) // released before the threshold
        sched.fireAll()
        #expect(rec.events.isEmpty)
    }

    @Test func holdReleaseDoesNotDoubleFireAndTogglesOnSecondLongPress() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .holdRelease), sched)
        // First long-press → tap on.
        tap.handleFlags([.leftOption])
        sched.fireAll()
        sched.fireAll()
        #expect(rec.events == [.intent(.transcription, .tap)])
        // Still holding the same chord must not re-arm a second toggle (cooldown).
        tap.handleFlags([.leftOption])
        sched.fireAll()
        #expect(rec.events == [.intent(.transcription, .tap)])
        // Clean release, then a fresh long-press toggles off.
        tap.handleFlags([])
        tap.handleFlags([.leftOption])
        sched.fireAll()
        sched.fireAll()
        #expect(rec.events == [.intent(.transcription, .tap), .intent(.transcription, .tap)])
    }

    // MARK: Disambiguation, interruption, stop, cooldown

    @Test func supersetChordWinsOverSubset() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .hold, askMode: .hold), sched)
        tap.handleFlags([.leftOption]) // arms Transcription
        tap.handleFlags([.leftOption, .leftControl]) // retargets to Ask (superset)
        sched.fireAll()
        #expect(rec.events == [.intent(.ask, .press)])
    }

    @Test func keyDuringChordCancelsTheGesture() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .hold), sched)
        tap.handleFlags([.leftOption]) // arms Transcription
        _ = tap.handleKeyDown(keyCode: UInt16(kVK_ANSI_E), sides: [.leftOption]) // ⌥e typing → cancel
        sched.fireAll()
        #expect(rec.events.isEmpty)
    }

    @Test func stopKeyFiresAndConsumesOnlyWhenSessionActive() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .hold), sched)
        rec.sessionActive = false
        let consumedIdle = tap.handleKeyDown(keyCode: UInt16(kVK_Escape), sides: [])
        #expect(rec.events == [.stop])
        #expect(consumedIdle == false)
        rec.sessionActive = true
        let consumedActive = tap.handleKeyDown(keyCode: UInt16(kVK_Escape), sides: [])
        #expect(consumedActive == true)
        #expect(rec.events == [.stop, .stop])
    }

    @Test func cooldownBlocksReArmUntilCleanRelease() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .hold, askMode: .hold), sched)
        tap.handleFlags([.leftOption, .leftControl]) // arm Ask
        sched.fireAll() // press Ask
        #expect(rec.events == [.intent(.ask, .press)])
        // Drop ⌃ but keep ⌥: Ask releases, and the leftover ⌥ must NOT immediately fire Transcription.
        tap.handleFlags([.leftOption])
        sched.fireAll()
        #expect(rec.events == [.intent(.ask, .press), .intent(.ask, .release)])
    }

    // MARK: Feature enable gating

    @Test func disabledAskTriggerChordFiresNothingAndClearsTranscriptionLatch() {
        // Ask off, both in Trigger: pressing the Ask superset (⌥⌃) must fire nothing - not Ask, and
        // not the Transcription (⌥) trigger candidate latched on the way up to the bigger chord.
        let sched = ManualGestureScheduler()
        var cfg = config(transcriptionMode: .trigger, askMode: .trigger)
        cfg.askEnabled = false
        let (tap, rec) = makeTap(cfg, sched)
        tap.handleFlags([.leftOption]) // latches the Transcription trigger candidate
        tap.handleFlags([.leftOption, .leftControl]) // Ask chord, disabled → clears the candidate
        tap.handleFlags([]) // full release
        #expect(rec.events.isEmpty)
    }

    @Test func enabledAskTriggerChordStillFires() {
        // Guard: clearing the latch must not regress the normal enabled case (⌥ → ⌥⌃ retargets Ask).
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(config(transcriptionMode: .trigger, askMode: .trigger), sched)
        tap.handleFlags([.leftOption])
        tap.handleFlags([.leftOption, .leftControl])
        tap.handleFlags([])
        #expect(rec.events == [.intent(.ask, .tap)])
    }

    @Test func disabledAskHoldChordFiresNothing() {
        let sched = ManualGestureScheduler()
        var cfg = config(transcriptionMode: .hold, askMode: .hold)
        cfg.askEnabled = false
        let (tap, rec) = makeTap(cfg, sched)
        tap.handleFlags([.leftOption, .leftControl]) // the (disabled) Ask chord
        sched.fireAll()
        #expect(rec.events.isEmpty)
    }

    @Test func disabledFeatureKeyChordFiresNothing() {
        // A disabled feature bound to a key chord must be skipped in handleKeyDown, not just in the
        // modifier-chord path.
        let chord = Hotkey(keyCode: UInt16(kVK_Space), modifiers: [.leftControl], keyLabel: "Space")
        var cfg = config(transcriptionMode: .trigger)
        cfg.translate = chord
        cfg.translateMode = .trigger
        cfg.translateEnabled = false
        let (tap, rec) = makeTap(cfg, ManualGestureScheduler())
        _ = tap.handleKeyDown(keyCode: UInt16(kVK_Space), sides: [.leftControl])
        #expect(rec.events.isEmpty)
    }

    @Test func disablingFeatureMidHoldCancelsActivePress() {
        // A live config push (e.g. toggling the feature off in Settings) while a Hold press is down
        // must deliver a terminal phase, not strand the session waiting for a release it forgot.
        let sched = ManualGestureScheduler()
        var cfg = config(transcriptionMode: .hold, askMode: .hold)
        let (tap, rec) = makeTap(cfg, sched)
        tap.handleFlags([.leftOption, .leftControl]) // arm Ask
        sched.fireAll() // press Ask
        #expect(rec.events == [.intent(.ask, .press)])
        cfg.askEnabled = false
        tap.updateConfig(cfg) // live reconfigure mid-press
        #expect(rec.events == [.intent(.ask, .press), .intent(.ask, .cancel)])
    }

    // MARK: Radial picker

    @Test func radialOpensAfterCleanHoldAndCommitsOnRelease() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(radialConfig(), sched)
        tap.handleFlags([.leftOption]) // arm the open-delay
        #expect(rec.events.isEmpty) // not open until the delay elapses
        sched.fireAll() // open delay elapses, still cleanly held → open
        #expect(rec.events == [.radialOpen])
        tap.handleFlags([]) // release → commit
        #expect(rec.events == [.radialOpen, .radialClose])
    }

    @Test func radialDoesNotFirePerModeChordWhenEnabled() {
        // left ⌥ is Transcription's chord *and* the radial trigger; with the wheel on it must open the
        // wheel, never start Transcription.
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(radialConfig(), sched)
        tap.handleFlags([.leftOption])
        sched.fireAll()
        #expect(rec.events == [.radialOpen])
        #expect(!rec.events.contains(.intent(.transcription, .press)))
    }

    @Test func radialArrowSelectsAndIsConsumed() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(radialConfig(), sched)
        tap.handleFlags([.leftOption]); sched.fireAll() // open
        let consumed = tap.handleKeyDown(keyCode: UInt16(kVK_UpArrow), sides: [.leftOption])
        #expect(consumed) // swallowed so it doesn't move the background app's cursor
        #expect(rec.events == [.radialOpen, .radialArrow(.up)])
    }

    @Test func quickModifierArrowDoesNotOpenWheel() {
        // ⌥+arrow word-navigation (a key arriving before the open delay) must not pop the wheel, and
        // the arrow must pass through (not be consumed).
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(radialConfig(), sched)
        tap.handleFlags([.leftOption]) // arm
        let consumed = tap.handleKeyDown(keyCode: UInt16(kVK_LeftArrow), sides: [.leftOption])
        #expect(!consumed)
        sched.fireAll() // the stale arm timer fires but its guard swallows it
        tap.handleFlags([])
        #expect(rec.events.isEmpty)
    }

    @Test func escCancelsAnOpenWheel() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(radialConfig(), sched)
        tap.handleFlags([.leftOption]); sched.fireAll() // open
        let consumed = tap.handleKeyDown(keyCode: UInt16(kVK_Escape), sides: [.leftOption])
        #expect(consumed)
        #expect(rec.events == [.radialOpen, .radialCancel])
        tap.handleFlags([]) // the trailing modifier release no longer commits
        #expect(rec.events == [.radialOpen, .radialCancel])
    }

    @Test func updateConfigWhileWheelOpenCancelsIt() {
        let sched = ManualGestureScheduler()
        let (tap, rec) = makeTap(radialConfig(), sched)
        tap.handleFlags([.leftOption]); sched.fireAll() // open
        tap.updateConfig(radialConfig()) // a live config push mid-hold must not strand the wheel
        #expect(rec.events == [.radialOpen, .radialCancel])
    }

    @Test func keyChordTriggerOpensOnKeyDownAndCommitsOnKeyUp() {
        let space = Hotkey(keyCode: UInt16(kVK_Space), modifiers: [.leftOption], keyLabel: "Space")
        let (tap, rec) = makeTap(radialConfig(radial: space), ManualGestureScheduler())
        let consumed = tap.handleKeyDown(keyCode: UInt16(kVK_Space), sides: [.leftOption])
        #expect(consumed)
        #expect(rec.events == [.radialOpen]) // a key chord opens immediately (no clean-hold delay)
        tap.handleKeyUp(keyCode: UInt16(kVK_Space))
        #expect(rec.events == [.radialOpen, .radialClose])
    }
}
