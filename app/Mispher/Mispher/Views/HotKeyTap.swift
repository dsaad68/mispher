import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Schedules a delayed, main-actor callback. Abstracted so the gesture timers (the modifier
/// debounce, the push-to-talk start delay, the hold-and-release long-press) can run on real time
/// in the app and be fired deterministically from tests.
@MainActor
protocol GestureScheduler {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void)
}

/// Production scheduler: sleeps on a `Task` and runs the work back on the main actor.
struct RealGestureScheduler: GestureScheduler {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }
}

/// The global keyboard engine behind the shortcuts (Transcription / Ask / Rewrite / Translate /
/// Stop). It tracks the live held-modifier set to recognise **bare-modifier chords** (e.g. left ⌥,
/// left ⌥+⌃) as well as key chords, with left/right awareness, and drives three activation modes
/// per shortcut:
/// - **hold** (push to talk): fire `.press` once held (optionally after a start delay), `.release`
///   on let-go.
/// - **trigger**: fire `.tap` on tap.
/// - **holdRelease** (hold & release): fire `.tap` after a long-press (toggles a session that
///   persists after release); a second long-press fires `.tap` again to finish.
/// Esc-Stop is consumed only while a session is active.
///
/// When Accessibility is granted it uses a system-wide `CGEventTap` (works unfocused and can
/// swallow Esc); otherwise it falls back to a focus-only local `NSEvent` monitor so the app
/// is never fully broken before the user grants access.
@MainActor
final class HotKeyTap {
    enum Phase { case press, release, tap, cancel }

    struct Config: Equatable {
        var transcription: Hotkey
        var ask: Hotkey
        /// Second Ask chord that continues the last conversation; has its own activation mode.
        var askContinue: Hotkey = .askContinueDefault
        var stop: Hotkey
        var rewrite: Hotkey
        var translate: Hotkey
        var transcriptionMode: ActivationMode
        var askMode: ActivationMode
        /// Activation mode for the Ask-continue chord. Defaults to `.hold` so callers that don't set
        /// it (e.g. tests) keep the old behavior.
        var askContinueMode: ActivationMode = .hold
        var rewriteMode: ActivationMode
        var translateMode: ActivationMode
        /// Seconds a push-to-talk chord must be held before recording begins (0 = instant, max 3).
        var pushToTalkStartDelay: TimeInterval = 0
        /// Seconds a hold-and-release chord must be held before it toggles recording on/off.
        var holdReleaseDuration: TimeInterval = 0.8
        /// Per-feature master switches. When off, that feature's chord never matches (the shortcut is
        /// inert). Default true so existing callers/tests keep firing every shortcut. Transcription is
        /// never gated here (Dictation = AI cleanup, not the transcribe shortcut).
        var rewriteEnabled = true
        var translateEnabled = true
        var askEnabled = true
        /// The hold-trigger for the radial mode picker (a bare-modifier chord, e.g. left ⌥).
        var radial: Hotkey = .radialDefault
        /// When on, holding `radial` pops the radial picker and the per-mode chords are inert -- the
        /// wheel becomes the single way to launch a mode. Default **false** so existing callers/tests
        /// keep the classic per-chord behavior; the app turns it on via ``shortcutConfig``.
        var radialEnabled = false
        /// Seconds the bare trigger must be held *cleanly* (no other key/modifier) before the wheel
        /// opens, so a quick ⌥+key or ⌥+arrow (word-nav) never pops it.
        var radialOpenDelay: TimeInterval = 0.3
    }

    /// Brief debounce before committing a bare-modifier chord, so ⌥-then-⌃ resolves to Ask
    /// (the superset) instead of momentarily firing Transcription.
    private let armingDelay: TimeInterval = 0.07

    private let scheduler: GestureScheduler

    init(scheduler: GestureScheduler = RealGestureScheduler()) {
        self.scheduler = scheduler
    }

    private var config = Config(
        transcription: .transcriptionDefault, ask: .askDefault, askContinue: .askContinueDefault,
        stop: .stopDefault, rewrite: .rewriteDefault, translate: .translateDefault,
        transcriptionMode: .hold, askMode: .hold, rewriteMode: .hold, translateMode: .hold
    )
    private var onIntent: (@MainActor (RecordIntent, Phase) -> Void)?
    private var onStop: (@MainActor () -> Void)?
    private var isSessionActive: (@MainActor () -> Bool)?
    // Radial picker callbacks: open the wheel, commit the highlighted slot on release, force-abort it
    // (config push / teardown mid-hold), and update the highlight from an arrow key.
    private var onRadialOpen: (@MainActor () -> Void)?
    private var onRadialClose: (@MainActor () -> Void)?
    private var onRadialCancel: (@MainActor () -> Void)?
    private var onRadialArrow: (@MainActor (RadialDirection) -> Void)?

    // Global tap
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var usingGlobalTap = false
    /// Bumped to cancel an in-flight cold-launch trust-upgrade retry (see ``scheduleTrustUpgrade``).
    private var trustRetryToken = 0
    // Local fallback
    private var localMonitor: Any?
    private var enabled = true

    // Chord/gesture tracking
    private var heldSides: Set<ModifierSide> = []
    private var pressIntent: RecordIntent? // a Hold press currently down
    private var pressKeyCode: UInt16? // its key (nil = modifier-only)
    private var armingIntent: RecordIntent? // a modifier chord awaiting the debounce
    private var armingToken = 0
    private var triggerCandidate: RecordIntent? // largest trigger chord seen this gesture
    private var sawKeyDuringChord = false
    private var cooldown = false // suppress re-arming until modifiers clear
    // A held gesture (modifier OR key) waiting on a duration timer before it commits: serves both
    // the push-to-talk start delay (fires `.press`) and the hold-and-release long-press (`.tap`).
    private var pendingIntent: RecordIntent?
    private var pendingKeyCode: UInt16? // nil = modifier-only pending
    private var pendingToken = 0 // bumped to cancel an in-flight timer
    // Radial picker gesture state.
    private var radialOpen = false // the wheel is showing
    private var radialArming = false // the trigger is held, waiting out the clean-hold open delay
    private var radialArmToken = 0 // bumped to cancel an in-flight open-delay timer
    private var radialKeyCode: UInt16? // the held key when the trigger is a key chord (nil = modifier-only)

    var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: Lifecycle

    func start(
        config: Config,
        onIntent: @escaping @MainActor (RecordIntent, Phase) -> Void,
        onStop: @escaping @MainActor () -> Void,
        isSessionActive: @escaping @MainActor () -> Bool,
        onRadialOpen: (@MainActor () -> Void)? = nil,
        onRadialClose: (@MainActor () -> Void)? = nil,
        onRadialCancel: (@MainActor () -> Void)? = nil,
        onRadialArrow: (@MainActor (RadialDirection) -> Void)? = nil
    ) {
        wire(
            config: config, onIntent: onIntent, onStop: onStop, isSessionActive: isSessionActive,
            onRadialOpen: onRadialOpen, onRadialClose: onRadialClose,
            onRadialCancel: onRadialCancel, onRadialArrow: onRadialArrow
        )
        install()
    }

    /// Set the config + callbacks without touching the OS event tap. Split out of `start` so tests
    /// can drive the gesture handlers (`handleFlags` / `handleKeyDown` / `handleKeyUp`) directly.
    func wire(
        config: Config,
        onIntent: @escaping @MainActor (RecordIntent, Phase) -> Void,
        onStop: @escaping @MainActor () -> Void,
        isSessionActive: @escaping @MainActor () -> Bool,
        onRadialOpen: (@MainActor () -> Void)? = nil,
        onRadialClose: (@MainActor () -> Void)? = nil,
        onRadialCancel: (@MainActor () -> Void)? = nil,
        onRadialArrow: (@MainActor (RadialDirection) -> Void)? = nil
    ) {
        self.config = config
        self.onIntent = onIntent
        self.onStop = onStop
        self.isSessionActive = isSessionActive
        self.onRadialOpen = onRadialOpen
        self.onRadialClose = onRadialClose
        self.onRadialCancel = onRadialCancel
        self.onRadialArrow = onRadialArrow
    }

    func updateConfig(_ config: Config) {
        self.config = config
        // A Hold press already delivered to the VM (`.press` fired) would otherwise be stranded: the
        // gesture is forgotten below, so the later physical release never reaches the VM and the
        // session runs until Stop. Cancel it first. (Reachable now that enable toggles, not just
        // shortcut rebinds, flow through `shortcutConfig`.)
        if let intent = pressIntent { onIntent?(intent, .cancel) }
        cancelRadialIfNeeded()
        resetTracking()
    }

    /// Stand the engine down (and reset tracking) while the Settings recorder captures keys.
    func setEnabled(_ on: Bool) {
        enabled = on
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
        if !on { cancelRadialIfNeeded(); resetTracking() }
    }

    /// Re-evaluate Accessibility trust and switch between the global tap and the local
    /// fallback if it changed (call when the user grants/revokes access).
    func refresh() {
        if isTrusted != usingGlobalTap { teardown(); install() }
    }

    func stop() {
        teardown()
        onIntent = nil; onStop = nil; isSessionActive = nil
    }

    // MARK: Install / teardown

    private func install() {
        if isTrusted {
            installGlobalTap()
        } else {
            // Cold launch: `AXIsProcessTrusted()` can read false for a beat even when Accessibility
            // is granted, so we land on the focus-only local monitor. Poll and promote to the global
            // tap the moment trust resolves, so global shortcuts work right after launch instead of
            // staying dead until the user opens Settings (which is what used to re-run `refresh()`).
            installLocalMonitor()
            scheduleTrustUpgrade()
        }
    }

    /// Retry the trust check after a cold launch and upgrade the local fallback to the global event
    /// tap once Accessibility reads as granted. `AXIsProcessTrusted()` can lag the real grant by a
    /// while at cold launch, and menu-bar-only launches have no window-focus event to recover on, so
    /// this polls well past the first few seconds (fast at first, then backing off) rather than
    /// giving up early. The app-active re-check (`AppDelegate.appDidBecomeActive`) covers the rest.
    /// Any ``teardown()`` (stop / refresh / a successful upgrade) bumps the token and ends the poll.
    private func scheduleTrustUpgrade(attempt: Int = 0) {
        // 0.5s polls for the first ~6s, then 2s polls out to ~60s total.
        let fastAttempts = 12
        guard attempt < fastAttempts + 27 else { return }
        let delay: TimeInterval = attempt < fastAttempts ? 0.5 : 2
        trustRetryToken &+= 1
        let token = trustRetryToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, trustRetryToken == token, !usingGlobalTap else { return }
            if isTrusted {
                teardown() // drop the focus-only local monitor...
                installGlobalTap() // ...and promote to the global tap
            }
            if !usingGlobalTap { scheduleTrustUpgrade(attempt: attempt + 1) }
        }
    }

    private func installGlobalTap() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<HotKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                // The run-loop source lives on the main run loop, so this fires on the main
                // thread → safe to touch main-actor state. (`assumeIsolated` can't *return*
                // the non-Sendable CGEvent, so write it through a local instead.)
                var result: Unmanaged<CGEvent>? = Unmanaged.passUnretained(event)
                MainActor.assumeIsolated { result = me.handle(type: type, event: event) }
                return result
            },
            userInfo: selfPtr
        )
        else { installLocalMonitor(); return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: enabled)
        usingGlobalTap = true
    }

    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { [weak self] event in
            guard let self, enabled else { return event }
            switch event.type {
            case .flagsChanged:
                handleFlags(Hotkey.sides(rawFlags: UInt64(event.modifierFlags.rawValue)))
                return event
            case .keyDown:
                let consume = handleKeyDown(
                    keyCode: event.keyCode,
                    sides: Hotkey.sides(rawFlags: UInt64(event.modifierFlags.rawValue))
                )
                return consume ? nil : event
            case .keyUp:
                handleKeyUp(keyCode: event.keyCode)
                return event
            default:
                return event
            }
        }
        usingGlobalTap = false
    }

    private func teardown() {
        trustRetryToken &+= 1 // cancel any pending cold-launch trust-upgrade retry
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        }
        tap = nil
        runLoopSource = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        cancelRadialIfNeeded()
        resetTracking()
    }

    // MARK: CGEvent dispatch

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
        case .flagsChanged:
            handleFlags(Hotkey.sides(rawFlags: event.flags.rawValue))
        case .keyDown:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if handleKeyDown(keyCode: keyCode, sides: Hotkey.sides(rawFlags: event.flags.rawValue)) {
                return nil // consume Esc-Stop while a session is active
            }
        case .keyUp:
            handleKeyUp(keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)))
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: Chord logic (shared by tap + local monitor; internal so tests can drive it)

    func handleFlags(_ sides: Set<ModifierSide>) {
        guard enabled else { return }
        heldSides = sides

        // The radial picker owns the trigger when enabled: it pre-empts the per-mode chord state
        // machine entirely (the wheel is the single launcher), so we resolve it and return.
        if config.radialEnabled { handleRadialFlags(sides); return }

        // A Hold modifier-press whose chord broke → release it.
        if let intent = pressIntent, pressKeyCode == nil,
           !hotkey(for: intent).matchesChord(heldSides: sides) {
            endHoldPress(intent)
        }
        // A pending arm that no longer matches → cancel it.
        if let armed = armingIntent, !hotkey(for: armed).matchesChord(heldSides: sides) {
            armingIntent = nil
            armingToken &+= 1
        }
        // A pending start-delay / long-press timer whose chord broke → cancel it. Releasing
        // before the threshold does nothing.
        if let pending = pendingIntent, pendingKeyCode == nil,
           !hotkey(for: pending).matchesChord(heldSides: sides) {
            clearPending()
        }
        // Fully released → resolve a Trigger tap and clear the gesture.
        if sides.isEmpty {
            if let intent = triggerCandidate, !sawKeyDuringChord {
                onIntent?(intent, .tap)
            }
            triggerCandidate = nil
            sawKeyDuringChord = false
            cooldown = false
            clearPending()
            return
        }
        // Still holding leftover modifiers after a release → wait for a clean start.
        if cooldown { return }

        // Does the current set exactly match a bound modifier-only chord?
        guard let intent = matchingModifierChord(sides) else {
            // The held set maps to no enabled chord (e.g. a disabled feature's chord, which is a
            // superset of a smaller one). A Trigger candidate latched from a subset of these keys
            // must not fire on release - otherwise a disabled chord still triggers the feature it
            // contains (e.g. Ask off, ⌥⌃ held, would fire Transcription's ⌥).
            if let cand = triggerCandidate, hotkey(for: cand).modifiers.isStrictSubset(of: sides) {
                triggerCandidate = nil
            }
            return
        }
        switch mode(for: intent) {
        case .hold, .holdRelease:
            if pressIntent == nil, pendingIntent == nil, armingIntent != intent { armModifierChord(intent) }
        case .trigger:
            triggerCandidate = intent // latest exact match wins (⌥ → ⌥⌃)
        }
    }

    /// Debounce a fresh modifier chord (70ms) to let supersets win, then -- if it still matches --
    /// schedule the mode's commit: push-to-talk waits out the start delay then `.press`;
    /// hold-and-release waits out the long-press duration then `.tap`.
    private func armModifierChord(_ intent: RecordIntent) {
        armingIntent = intent
        armingToken &+= 1
        let token = armingToken
        sawKeyDuringChord = false
        scheduler.schedule(after: armingDelay) { [weak self] in
            guard let self, armingToken == token, armingIntent == intent else { return }
            armingIntent = nil
            guard hotkey(for: intent).matchesChord(heldSides: heldSides), !sawKeyDuringChord else { return }
            switch mode(for: intent) {
            case .hold:
                let delay = config.pushToTalkStartDelay
                if delay <= 0 {
                    beginHoldPress(intent, keyCode: nil)
                } else {
                    scheduleHeldFire(intent, keyCode: nil, delay: delay, phase: .press)
                }
            case .holdRelease:
                scheduleHeldFire(intent, keyCode: nil, delay: config.holdReleaseDuration, phase: .tap)
            case .trigger:
                break // handled via triggerCandidate
            }
        }
    }

    /// Hold a just-recognised gesture for `delay`, then fire `phase` if it's still held and
    /// uninterrupted. Releasing early (which bumps `pendingToken`) cancels cleanly with no
    /// recording. `.press` promotes the gesture to a Hold press so the release path fires
    /// `.release`; `.tap` leaves it un-held so a hold-and-release session persists after let-go.
    private func scheduleHeldFire(_ intent: RecordIntent, keyCode: UInt16?, delay: TimeInterval, phase: Phase) {
        pendingIntent = intent
        pendingKeyCode = keyCode
        pendingToken &+= 1
        let token = pendingToken
        scheduler.schedule(after: delay) { [weak self] in
            guard let self, pendingToken == token, pendingIntent == intent else { return }
            if let kc = keyCode {
                guard hotkey(for: intent).matchesKey(keyCode: kc, heldSides: heldSides) else { clearPending(); return }
            } else {
                guard hotkey(for: intent).matchesChord(heldSides: heldSides), !sawKeyDuringChord else { clearPending(); return }
            }
            clearPending()
            switch phase {
            case .press:
                beginHoldPress(intent, keyCode: keyCode)
            case .tap:
                // Hold & release: the recording persists after release. Block a second toggle from
                // the still-held modifier chord until a clean release.
                if keyCode == nil { cooldown = true }
                onIntent?(intent, .tap)
            case .release, .cancel:
                onIntent?(intent, phase)
            }
        }
    }

    private func beginHoldPress(_ intent: RecordIntent, keyCode: UInt16?) {
        pressIntent = intent
        pressKeyCode = keyCode
        onIntent?(intent, .press)
    }

    func handleKeyDown(keyCode: UInt16, sides: Set<ModifierSide>) -> Bool {
        guard enabled else { return false }
        heldSides = sides

        if config.radialEnabled {
            // While the wheel is up, arrows steer it and Esc cancels it -- both consumed so they
            // don't reach the background app; any other key just passes through (wheel stays up).
            if radialOpen {
                if let dir = RadialDirection.from(arrowKeyCode: keyCode) { onRadialArrow?(dir); return true }
                if keyCode == UInt16(kVK_Escape) { onRadialCancel?(); radialOpen = false; return true }
                return false
            }
            // A key during the clean-hold open delay = normal ⌥+key use -> cancel the arm so a quick
            // ⌥+arrow word-jump (or ⌥+letter) never pops the wheel.
            if radialArming { sawKeyDuringChord = true; cancelRadialArm() }
            // A key-chord trigger (e.g. ⌥Space) opens immediately on its key press -- a key press is
            // already deliberate, so no clean-hold delay -- and is consumed.
            if !radialOpen, !config.radial.isModifierOnly,
               config.radial.matchesKey(keyCode: keyCode, heldSides: sides) {
                radialOpen = true
                radialKeyCode = keyCode
                onRadialOpen?()
                return true
            }
        }

        // Stop key (e.g. Esc): fire, and consume only while a session is active.
        if config.stop.matchesKey(keyCode: keyCode, heldSides: sides) {
            onStop?()
            return isSessionActive?() ?? false
        }

        // The radial picker replaces the per-mode chords, so none of them match while it's enabled.
        if config.radialEnabled { return false }

        // A key arriving during a modifier chord = normal modifier use, not a talk gesture: cancel
        // an in-flight modifier hold/arm/trigger/long-press so bare-⌥ doesn't hijack ⌥+key typing.
        if armingIntent != nil || triggerCandidate != nil
            || (pendingIntent != nil && pendingKeyCode == nil)
            || (pressIntent != nil && pressKeyCode == nil) {
            sawKeyDuringChord = true
            if let intent = pressIntent, pressKeyCode == nil { endHoldPress(intent, cancel: true) }
            if armingIntent != nil { armingIntent = nil; armingToken &+= 1 }
            if pendingIntent != nil, pendingKeyCode == nil { clearPending() }
            triggerCandidate = nil
        }

        // Key-chord bindings (check supersets first so they win).
        for intent in [RecordIntent.translate, .ask, .askContinue, .rewrite, .transcription] {
            guard isEnabled(intent) else { continue }
            let hk = hotkey(for: intent)
            guard !hk.isModifierOnly, hk.matchesKey(keyCode: keyCode, heldSides: sides) else { continue }
            switch mode(for: intent) {
            case .hold:
                let delay = config.pushToTalkStartDelay
                if delay <= 0 {
                    beginHoldPress(intent, keyCode: keyCode)
                } else {
                    scheduleHeldFire(intent, keyCode: keyCode, delay: delay, phase: .press)
                }
            case .holdRelease:
                scheduleHeldFire(intent, keyCode: keyCode, delay: config.holdReleaseDuration, phase: .tap)
            case .trigger:
                onIntent?(intent, .tap)
            }
            break
        }
        return false
    }

    func handleKeyUp(keyCode: UInt16) {
        guard enabled else { return }
        // A key-chord radial trigger released → commit the highlighted slot.
        if radialOpen, radialKeyCode == keyCode {
            radialOpen = false
            radialKeyCode = nil
            onRadialClose?()
            return
        }
        // Released before the start-delay / long-press threshold → nothing happens.
        if pendingIntent != nil, pendingKeyCode == keyCode { clearPending(); return }
        if let intent = pressIntent, pressKeyCode == keyCode { endHoldPress(intent) }
    }

    private func endHoldPress(_ intent: RecordIntent, cancel: Bool = false) {
        pressIntent = nil
        pressKeyCode = nil
        cooldown = !heldSides.isEmpty // require a clean release before the next chord
        onIntent?(intent, cancel ? .cancel : .release)
    }

    private func clearPending() {
        pendingIntent = nil
        pendingKeyCode = nil
        pendingToken &+= 1
    }

    private func resetTracking() {
        heldSides = []
        pressIntent = nil
        pressKeyCode = nil
        armingIntent = nil
        armingToken &+= 1
        triggerCandidate = nil
        sawKeyDuringChord = false
        cooldown = false
        pendingIntent = nil
        pendingKeyCode = nil
        pendingToken &+= 1
        radialOpen = false
        radialKeyCode = nil
        cancelRadialArm()
    }

    // MARK: Radial picker recognizer

    /// Resolve the radial trigger from the live modifier set: arm on a clean exact-match hold, open
    /// after the delay, and commit on release (or cancel the arm when the chord breaks early).
    private func handleRadialFlags(_ sides: Set<ModifierSide>) {
        // A key-chord trigger opens/commits via handleKeyDown/Up, so modifier changes must not touch
        // it -- only a modifier-only trigger is resolved here.
        guard config.radial.isModifierOnly else { return }
        let matches = config.radial.matchesChord(heldSides: sides)
        if radialOpen {
            // Released or an extra modifier added → commit whatever slot is highlighted.
            if !matches { radialOpen = false; onRadialClose?() }
            return
        }
        if radialArming {
            if !matches { cancelRadialArm() } // broke before opening → no wheel
            return
        }
        guard matches else { return }
        radialArming = true
        sawKeyDuringChord = false
        radialArmToken &+= 1
        let token = radialArmToken
        scheduler.schedule(after: config.radialOpenDelay) { [weak self] in
            guard let self, radialArming, radialArmToken == token else { return }
            radialArming = false
            // Only open if the exact trigger is still held cleanly (no stray key arrived meanwhile).
            guard config.radial.matchesChord(heldSides: heldSides), !sawKeyDuringChord else { return }
            radialOpen = true
            onRadialOpen?()
        }
    }

    /// Cancel an in-flight open-delay timer (bumping the token so its closure no-ops).
    private func cancelRadialArm() {
        radialArming = false
        radialArmToken &+= 1
    }

    /// Force the wheel down without launching (config push / teardown / disable mid-hold).
    private func cancelRadialIfNeeded() {
        if radialOpen { radialOpen = false; onRadialCancel?() }
        radialKeyCode = nil
        cancelRadialArm()
    }

    // MARK: Helpers

    private func matchingModifierChord(_ sides: Set<ModifierSide>) -> RecordIntent? {
        // Supersets first (Translate > Ask-continue > Ask > Rewrite > Transcription), skipping any
        // feature switched off so its chord stays inert.
        for intent in [RecordIntent.translate, .askContinue, .ask, .rewrite, .transcription] {
            guard isEnabled(intent) else { continue }
            let hk = hotkey(for: intent)
            if hk.isModifierOnly, hk.matchesChord(heldSides: sides) { return intent }
        }
        return nil
    }

    /// Whether the feature behind `intent` is switched on in Settings. Transcription and Stop are
    /// always on; Rewrite, Translate, and Ask (both Ask chords) follow their master toggle.
    private func isEnabled(_ intent: RecordIntent) -> Bool {
        switch intent {
        case .rewrite: return config.rewriteEnabled
        case .translate: return config.translateEnabled
        case .ask, .askContinue: return config.askEnabled
        case .transcription: return true
        }
    }

    private func hotkey(for intent: RecordIntent) -> Hotkey {
        switch intent {
        case .ask: return config.ask
        case .askContinue: return config.askContinue
        case .rewrite: return config.rewrite
        case .translate: return config.translate
        case .transcription: return config.transcription
        }
    }

    private func mode(for intent: RecordIntent) -> ActivationMode {
        switch intent {
        // The two Ask chords differ in new-vs-continue and now carry independent modes.
        case .ask: return config.askMode
        case .askContinue: return config.askContinueMode
        case .rewrite: return config.rewriteMode
        case .translate: return config.translateMode
        case .transcription: return config.transcriptionMode
        }
    }
}
