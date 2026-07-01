import Carbon.HIToolbox
import DeepAgents
import Foundation

/// Pure finish/silence decisions and the settings persistence (shortcuts, activation modes, the new
/// timing tunings, recording presentation, MCP servers). Split out of ``TranscriptionViewModel`` so
/// the main file stays within the length limit; the helpers are deterministic and unit-tested.
@MainActor
extension TranscriptionViewModel {
    /// The radial mode picker keys: its hold-trigger binding, master on/off switch, slot layout, and
    /// the pop-up dial's size (a 0.5...1.0 fraction of full).
    static let radialShortcutKey = "mispher.radialShortcut"
    static let radialEnabledKey = "mispher.radialEnabled"
    static let radialLayoutKey = "mispher.radialLayout"
    static let radialScaleKey = "mispher.radialScale"

    /// The wheel's direction → mode layout, defaulting (and self-healing from a corrupt store) to
    /// ``RadialLayout/default``. `defaults` is injectable for tests.
    static func loadRadialLayout(defaults: UserDefaults = .standard) -> RadialLayout {
        (defaults.array(forKey: radialLayoutKey) as? [String]).flatMap(RadialLayout.init(rawValues:)) ?? .default
    }

    static func saveRadialLayout(_ layout: RadialLayout, defaults: UserDefaults = .standard) {
        defaults.set(layout.rawValues, forKey: radialLayoutKey)
    }

    // MARK: - Finish + silence decisions

    /// What a finished transcription does, derived from the finish-behavior setting.
    enum FinishAction { case pause, stop }

    /// Pause vs stop for a finishing recording: only transcription honors the user's setting;
    /// ask/rewrite/translate always finalize on their finish gesture.
    static func finishAction(intent: RecordIntent, behavior: TranscriptionFinishBehavior) -> FinishAction {
        guard intent == .transcription else { return .stop }
        return behavior == .stop ? .stop : .pause
    }

    /// Whether to arm silence auto-end for the recording about to start, tracing the decision so a
    /// "never auto-ends" report can be diagnosed from the logs (filter by "MISPHER_TI silence-arm").
    func armedForSilence() -> Bool {
        let armed = Self.shouldArmSilence(enabled: silenceAutoEndEnabled, mode: activeMode)
        SystemTextAccess.tlog(
            "silence-arm intent=\(activeIntent) mode=\(activeMode) on=\(silenceAutoEndEnabled) armed=\(armed)"
        )
        return armed
    }

    /// Whether the silence detector arms for a recording in `mode`.
    ///
    /// **Hold & release** is the hands-free mode: you long-press to toggle it on and it keeps
    /// recording after you let go, so the silence timeout is its primary stop (alongside a second
    /// long-press or the Stop shortcut). It therefore *always* auto-ends on silence, independent of
    /// the `enabled` toggle. **Trigger** opts in via the toggle (you can otherwise tap to stop).
    /// **Push-to-talk** never arms - releasing the key ends the segment.
    static func shouldArmSilence(enabled: Bool, mode: ActivationMode) -> Bool {
        switch mode {
        case .holdRelease: return true
        case .trigger: return enabled
        case .hold: return false
        }
    }

    /// The activation mode of the shortcut that started the current session, keyed on the raw
    /// intent so a continue session uses `askContinueMode`, not `askMode`.
    var activeMode: ActivationMode {
        // A radial-launched session commits on key release, so it runs Trigger-style regardless of
        // the target mode's per-chord setting (which the wheel replaces).
        if sessionFromRadial { return .trigger }
        switch activeRawIntent {
        case .ask: return askMode
        case .askContinue: return askContinueMode
        case .rewrite: return rewriteMode
        case .translate: return translateMode
        case .transcription: return transcriptionMode
        }
    }

    /// True when any shortcut is in Hold & release. That mode always auto-ends on silence (see
    /// ``shouldArmSilence(enabled:mode:)``), so the Settings silence-length picker stays available
    /// even with the (Trigger-only) "Auto-end on silence" toggle off.
    var usesHoldRelease: Bool {
        transcriptionMode == .holdRelease || askMode == .holdRelease || askContinueMode == .holdRelease
            || rewriteMode == .holdRelease || translateMode == .holdRelease
    }

    /// What the current recording is for (drives whether finalize sends the transcript to the Ask
    /// model). The two Ask shortcuts collapse to `.ask` here -- see ``RecordIntent/asActiveIntent``.
    var activeIntent: RecordIntent { activeRawIntent.asActiveIntent }

    /// The post-speech silence window for the active intent: Ask gets `askSilenceFloor` of headroom;
    /// every other intent uses the user's `silenceTimeout` unchanged.
    var effectiveSilenceTimeout: TimeInterval {
        activeIntent == .ask ? max(silenceTimeout, Self.askSilenceFloor) : silenceTimeout
    }

    /// The shortcuts + their modes (including the radial picker), bundled for the `AppDelegate` to
    /// hand to ``HotKeyTap``.
    var shortcutConfig: HotKeyTap.Config {
        .init(
            transcription: transcriptionShortcut, ask: askShortcut, askContinue: askContinueShortcut,
            stop: stopShortcut, rewrite: rewriteShortcut, translate: translateShortcut,
            transcriptionMode: transcriptionMode, askMode: askMode, askContinueMode: askContinueMode,
            rewriteMode: rewriteMode, translateMode: translateMode,
            pushToTalkStartDelay: pushToTalkStartDelay, holdReleaseDuration: holdReleaseDuration,
            rewriteEnabled: rewriteEnabled, translateEnabled: translateEnabled, askEnabled: askEnabled,
            radial: radialShortcut, radialEnabled: radialEnabled
        )
    }

    /// Launch (or finalize) the mode chosen from the radial picker. Reuses the Trigger-tap path so
    /// every per-mode setup hook still runs (``beginRewriteCapture()``, ``beginDictationCapture()``,
    /// ``activateAsk(fresh:)``) - no duplication. Picking the same mode again while it records stops it
    /// (the symmetric Trigger toggle); a different mode mid-session is ignored downstream.
    func startRadialMode(_ rawIntent: RecordIntent) {
        if !isSessionActive { pendingRadialLaunch = true }
        shortcutTapped(rawIntent)
    }

    // MARK: - Reset

    /// True when every shortcut binding, mode, and timing tuning is already at its default.
    var shortcutsAreDefault: Bool {
        transcriptionShortcut == .transcriptionDefault && askShortcut == .askDefault
            && askContinueShortcut == .askContinueDefault
            && rewriteShortcut == .rewriteDefault && translateShortcut == .translateDefault
            && stopShortcut == .stopDefault
            && radialShortcut == .radialDefault && radialEnabled && radialLayout == .default && radialScale == 1
            && transcriptionMode == .hold && askMode == .hold && askContinueMode == .hold
            && rewriteMode == .hold && translateMode == .hold
            && pushToTalkStartDelay == 0 && holdReleaseDuration == 0.8
            && silenceAutoEndEnabled && silenceTimeout == SilenceDetector.defaultTimeout
            && transcriptionFinishBehavior == .pause
    }

    /// Restore every shortcut binding, activation mode, and timing tuning to its default. Each
    /// property's `didSet` persists the change, so the engine reconfigures on the next config push.
    func resetShortcuts() {
        transcriptionShortcut = .transcriptionDefault
        askShortcut = .askDefault
        askContinueShortcut = .askContinueDefault
        rewriteShortcut = .rewriteDefault
        translateShortcut = .translateDefault
        stopShortcut = .stopDefault
        radialShortcut = .radialDefault
        radialEnabled = true
        radialLayout = .default
        radialScale = 1
        transcriptionMode = .hold
        askMode = .hold
        askContinueMode = .hold
        rewriteMode = .hold
        translateMode = .hold
        pushToTalkStartDelay = 0
        holdReleaseDuration = 0.8
        silenceAutoEndEnabled = true
        silenceTimeout = SilenceDetector.defaultTimeout
        transcriptionFinishBehavior = .pause
    }

    // MARK: - Shortcut persistence

    static func loadHotkey(_ key: String, legacyKey: String? = nil) -> Hotkey? {
        if let data = UserDefaults.standard.data(forKey: key),
           let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data) {
            return hotkey
        }
        // Migrate a binding saved by an older build (legacy `KeyCombo` JSON under the old key)
        // so upgrading users keep their shortcut instead of silently resetting to default.
        if let legacyKey, let data = UserDefaults.standard.data(forKey: legacyKey) {
            return (try? JSONDecoder().decode(LegacyKeyCombo.self, from: data))?.asHotkey
        }
        return nil
    }

    static func saveHotkey(_ hotkey: Hotkey, _ key: String) {
        if let data = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Load a Bool that defaults to `true` when unset (a fresh install). Used by the per-feature
    /// master switches so Rewrite / Translation / Ask stay on for existing and new users alike.
    /// `defaults` is injectable for tests.
    static func loadBoolDefaultTrue(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    /// Whether the Dictation AI-cleanup feature is on. Defaults to off and migrates the legacy
    /// "Clean up dictation with AI" value the first time the new key is absent, so upgrading users
    /// keep their prior cleanup choice. `defaults` is injectable for tests.
    static func loadDictationEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: dictationEnabledKey) != nil {
            return defaults.bool(forKey: dictationEnabledKey)
        }
        return defaults.bool(forKey: cleanupWithAIKey)
    }

    /// Load a per-shortcut activation mode, migrating the pre-overhaul `"handsFree"` value: that
    /// mode is gone, so map it to `.trigger` (the gesture it shared) and turn on the now-global
    /// `silenceAutoEndEnabled` once so those users keep auto-finish. Idempotent (writes the migrated
    /// value back). `defaults` is injectable for tests.
    static func loadMode(_ key: String, defaults: UserDefaults = .standard) -> ActivationMode {
        guard let raw = defaults.string(forKey: key) else { return .hold }
        if raw == "handsFree" {
            defaults.set(ActivationMode.trigger.rawValue, forKey: key)
            if defaults.object(forKey: silenceAutoEndEnabledKey) == nil {
                defaults.set(true, forKey: silenceAutoEndEnabledKey)
            }
            return .trigger
        }
        return ActivationMode(rawValue: raw) ?? .hold
    }

    /// Load a seconds value, clamped to `[lo, hi]`; returns `def` when unset. `defaults` injectable.
    static func loadClamped(
        _ key: String, default def: TimeInterval, min lo: TimeInterval, max hi: TimeInterval,
        defaults: UserDefaults = .standard
    ) -> TimeInterval {
        guard defaults.object(forKey: key) != nil else { return def }
        return Swift.min(hi, Swift.max(lo, defaults.double(forKey: key)))
    }

    /// Load the transcription finish behavior; defaults to `.pause` (preserving the prior behavior).
    static func loadFinishBehavior(defaults: UserDefaults = .standard) -> TranscriptionFinishBehavior {
        (defaults.string(forKey: transcriptionFinishBehaviorKey))
            .flatMap(TranscriptionFinishBehavior.init(rawValue:)) ?? .pause
    }

    static func loadRecordingPresentation() -> RecordingPresentation {
        let stored = (UserDefaults.standard.string(forKey: recordingPresentationKey))
            .flatMap(RecordingPresentation.init(rawValue:))
        // The main-window style is gone (there is no transcript HUD now), so migrate it - and the
        // unset default - to the Floating overlay.
        guard let stored, stored != .mainWindow else { return .floating }
        return stored
    }

    static func loadAskPresentation() -> RecordingPresentation {
        // Ask uses its own overlay style by default (the Dynamic Island), distinct from voice modes.
        let isIndependent = loadBoolDefaultTrue("mispher.askPresentationIndependent")
        if isIndependent {
            if let raw = UserDefaults.standard.string(forKey: askPresentationKey),
               let value = RecordingPresentation(rawValue: raw), value != .mainWindow {
                return value
            }
            return .dynamicIsland
        }
        // Not independent: boot from the voice-modes value so Ask stays in sync.
        return loadRecordingPresentation()
    }

    // MARK: - MCP server persistence

    static func loadMCPServers() -> [MCPServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: mcpServersKey) else { return [] }
        return (try? JSONDecoder().decode([MCPServerConfig].self, from: data)) ?? []
    }

    static func saveMCPServers(_ servers: [MCPServerConfig]) {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: mcpServersKey)
        }
    }

    // MARK: - Agent tool policy persistence

    static func loadAgentToolPolicy() -> AgentToolPolicy {
        guard let data = UserDefaults.standard.data(forKey: agentToolPolicyKey) else {
            return AgentToolPolicy()
        }
        return (try? JSONDecoder().decode(AgentToolPolicy.self, from: data)) ?? AgentToolPolicy()
    }

    static func saveAgentToolPolicy(_ policy: AgentToolPolicy) {
        if let data = try? JSONEncoder().encode(policy) {
            UserDefaults.standard.set(data, forKey: agentToolPolicyKey)
        }
    }

    /// Hand the manager the current MCP servers + tool policy so the next deep-agent run uses the
    /// latest Settings. Cheap to call repeatedly; the live MCP client only rebuilds when the
    /// enabled-server set actually changes.
    func pushAgentToolConfig() {
        mlxModels?.setAgentToolConfig(mcpServers: mcpServers, policy: agentToolPolicy)
    }
}

/// The shape of a shortcut saved by builds before the side-aware `Hotkey` (the old `KeyCombo`):
/// a key code plus a Carbon modifier mask. Decoded only to migrate those bindings forward. Carbon
/// masks carry no left/right side, so modifiers map to the left side -- the same assumption
/// `Hotkey.sides` makes when an event reports no side.
private struct LegacyKeyCombo: Decodable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    var asHotkey: Hotkey? {
        guard let code = UInt16(exactly: keyCode) else { return nil }
        var sides: Set<ModifierSide> = []
        if carbonModifiers & UInt32(cmdKey) != 0 { sides.insert(.leftCommand) }
        if carbonModifiers & UInt32(optionKey) != 0 { sides.insert(.leftOption) }
        if carbonModifiers & UInt32(controlKey) != 0 { sides.insert(.leftControl) }
        if carbonModifiers & UInt32(shiftKey) != 0 { sides.insert(.leftShift) }
        return Hotkey(keyCode: code, modifiers: sides, keyLabel: keyLabel)
    }
}
