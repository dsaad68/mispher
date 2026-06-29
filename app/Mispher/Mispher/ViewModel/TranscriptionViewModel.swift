import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DeepAgents
import DeepAgentsMLX
import Foundation
import Observation

/// Orchestrates engine selection, mic capture, and the recording state machine.
/// All UI state lives here and is observed by the SwiftUI views.
@MainActor
@Observable
final class TranscriptionViewModel {
    private static let autoCopyKey = "mispher.autoCopyOnFinish"
    static let selectedModelKey = "mispher.selectedModel"
    static let recordingPresentationKey = "mispher.recordingPresentation"
    static let askPresentationKey = "mispher.askPresentation"
    private static let floatingFollowsPointerKey = "mispher.floatingFollowsPointer"
    private static let selectedInputDeviceKey = "mispher.selectedInputDeviceUID"
    private static let nemotronLanguageKey = "mispher.nemotronLanguage"
    static let translationEnabledKey = "mispher.translationEnabled"
    private static let translationModelKey = "mispher.translationModelId"
    static let translationPromptKey = "mispher.translationPrompt"
    static let translationPromptInputMigratedKey = "mispher.translationPromptInputMigrated"
    static let translationTargetKey = "mispher.translationTargetLanguage"
    /// Legacy on/off key, read once to migrate users who had Translate→English on.
    static let legacyTranslateEnabledKey = "mispher.translateToEnglish"
    private static let transcriptionShortcutKey = "mispher.transcriptionShortcut"
    private static let askShortcutKey = "mispher.askShortcut"
    private static let askContinueShortcutKey = "mispher.askContinueShortcut"
    private static let rewriteShortcutKey = "mispher.rewriteShortcut"
    private static let translateShortcutKey = "mispher.translateShortcut"
    private static let stopShortcutKey = "mispher.stopShortcutV2"
    /// Legacy shortcut keys (pre-side-aware `Hotkey`), read once to migrate old `KeyCombo`
    /// bindings so upgrading users don't lose them. Talk maps to Transcription; Ask is new.
    private static let legacyTalkShortcutKey = "mispher.talkShortcut"
    private static let legacyStopShortcutKey = "mispher.stopShortcut"
    private static let transcriptionModeKey = "mispher.transcriptionMode"
    private static let askModeKey = "mispher.askMode"
    private static let askContinueModeKey = "mispher.askContinueMode"
    static let mcpServersKey = "mispher.mcpServers"
    static let agentToolPolicyKey = "mispher.agentToolPolicy"
    private static let rewriteModeKey = "mispher.rewriteMode"
    private static let translateModeKey = "mispher.translateMode"
    private static let pushToTalkStartDelayKey = "mispher.pushToTalkStartDelay"
    private static let holdReleaseDurationKey = "mispher.holdReleaseDuration"
    static let silenceAutoEndEnabledKey = "mispher.silenceAutoEndEnabled"
    private static let silenceTimeoutKey = "mispher.silenceTimeout"
    static let transcriptionFinishBehaviorKey = "mispher.transcriptionFinishBehavior"
    /// Legacy key for the old "Clean up dictation with AI" toggle; now read once to migrate into
    /// ``dictationEnabledKey``. Internal so ``loadDictationEnabled()`` (another file) can read it.
    static let cleanupWithAIKey = "mispher.cleanupDictationWithAI"
    private static let removeFillerWordsKey = "mispher.removeFillerWords"
    static let customDictionaryKey = "mispher.customDictionary"
    private static let cleanupModelKey = "mispher.cleanupModelId"
    static let cleanupPromptKey = "mispher.cleanupPrompt"
    private static let rewriteModelKey = "mispher.rewriteModelId"
    private static let rewritePromptKey = "mispher.rewritePrompt"
    /// Old combined cleanup+rewrite model key, read once to migrate to the split settings.
    private static let assistModelKey = "mispher.assistModelId"
    private static let hasCompletedOnboardingKey = "mispher.hasCompletedOnboarding"
    /// Master on/off switches. Rewrite / Translation / Ask default on (see ``loadBoolDefaultTrue(_:)``);
    /// when off the feature's shortcut is hidden and never fires. Dictation is the AI-cleanup switch
    /// (``loadDictationEnabled()``, default off, migrated from `cleanupWithAIKey`) - it never gates
    /// the transcription shortcut, only whether the transcript is sent to the model for cleanup.
    static let dictationEnabledKey = "mispher.dictationEnabled"
    static let rewriteEnabledKey = "mispher.rewriteEnabled"
    static let translateEnabledKey = "mispher.translateEnabled"
    static let askEnabledKey = "mispher.askEnabled"

    var state: RecordingState = .idle
    var partialText = ""
    var finalText = ""
    var statusMessage = "Select a model to begin."

    /// The translation of `finalText`, shown beneath the original once recording
    /// stops (only when `translationEnabled` is on). Cleared per session.
    var translatedText = ""
    /// True while the translation request is in flight, to show "Translating…".
    var isTranslating = false

    /// The streamed reply from the selected local model, shown beneath the
    /// transcript once recording stops (only when an Ask model is selected).
    /// Cleared per session.
    var askReplyText = ""
    /// True while a local-model reply is generating, to show "Thinking…".
    var isAsking = false

    /// The agent's execution timeline for the current answer — reasoning, tool calls, and
    /// to-do plan snapshots, in the order the model produced them. Cleared per session.
    var askTimeline: [AgentStep] = []
    /// The current round's text as it streams (reasoning, or the final answer being
    /// written), shown live until the round is folded into `askTimeline`/`askReplyText`.
    var askStreamingText = ""

    /// True while a voice-driven Ask/DeepAgent *conversation* is shown in a compact overlay
    /// (floating or dynamic island). Unlike the single-turn HUD Ask, this is sticky: it stays
    /// on across turns -- keeping the overlay up between questions -- until the user dismisses it
    /// (Stop/Esc, the card's close button, or "Open in HUD"). The conversation itself lives in
    /// the shared chat thread (``MlxModelManager`` keyed by the Ask selection id), so the overlay
    /// is just a compact lens on it and stays in sync with the HUD chat.
    var askOverlaySessionActive = false

    /// The voice-rewrite result, shown beneath the spoken instruction once it's applied to the
    /// selection. Cleared per session.
    var rewriteResultText = ""
    /// True while the on-device rewrite is generating, to show "Rewriting…".
    var isRewriting = false
    /// The text selected in the frontmost app when a Rewrite session began. Captured before
    /// focus changes; cleared after each rewrite. Internal so the text-insertion extension can reach it.
    var rewriteSelection = ""
    /// The accessibility element the rewrite result is written back into. Not observed.
    @ObservationIgnored var rewriteTargetElement: AXUIElement?
    /// The frontmost app captured for a Rewrite session. Used when the focused AX element belongs
    /// to a browser/Electron renderer process that cannot receive paste events itself.
    @ObservationIgnored var rewriteTargetPID: pid_t?
    /// The frontmost app's focused text field captured when a hotkey dictation began, so the
    /// finished transcript can be inserted there. nil when dictation started from the HUD itself
    /// (no external field) or Accessibility isn't granted. Captured before the HUD shows; cleared
    /// after each insert. Not observed.
    @ObservationIgnored var dictationTargetElement: AXUIElement?
    /// The frontmost app captured for dictation insertion. See ``rewriteTargetPID``.
    @ObservationIgnored var dictationTargetPID: pid_t?

    /// True while a `.transcription` session dictates into the chat composer (not an external app):
    /// capture skips the focused field, finalize commits into the chat field, ``ChatView`` mirrors it.
    var composerDictationActive = false

    /// The Ask target. Ask is DeepAgent-only: when enabled it's always the on-device DeepAgent
    /// sentinel (its planner + vision models are chosen in the Ask settings tab), and `nil` when
    /// off. Kept as the dispatch / conversation-pin / readiness key the rest of the app reads.
    var askModelId: String? { askEnabled ? DeepAgentVariant.deepAgentID : nil }

    /// Master switch for the Ask feature. When on, Ask runs the on-device DeepAgent; when off its
    /// shortcuts are hidden in Settings/onboarding and never fire (see ``shortcutConfig``). Default
    /// on. Toggling warms or frees the planner via ``MlxModelManager/setAskModel(_:)``.
    var askEnabled = TranscriptionViewModel.loadBoolDefaultTrue(TranscriptionViewModel.askEnabledKey) {
        didSet {
            UserDefaults.standard.set(askEnabled, forKey: Self.askEnabledKey)
            guard askEnabled != oldValue else { return }
            mlxModels?.setAskModel(askModelId)
        }
    }

    /// The on-device DeepAgent's model + idle-timeout choices (Ask "DeepAgent" entry); see ``DeepAgentSettings``.
    let deepAgent = DeepAgentSettings()

    /// True when the HUD body shows the standalone, type-only chat instead of the
    /// transcript + record controls. Transient (not persisted): chat is a session-like UI
    /// state, so a fresh launch always opens in transcription. The chat runs the same Ask
    /// DeepAgent, so entering chat just warms its planner — it isn't loaded on launch, only
    /// on demand.
    var chatMode = false {
        didSet {
            guard chatMode != oldValue else { return }
            if chatMode { mlxModels?.setAskModel(askModelId) }
        }
    }

    /// Whether the HUD chat routes through the on-device ReAct agent (clipboard + to-do
    /// tools and memory) vs. plain chat. Lives here so the toolbar's tools toggle and the
    /// chat both read it.
    var chatUseTools = true

    /// The model the user transcribes with. Persisted in `UserDefaults`.
    var selectedModel: AsrModel = TranscriptionViewModel.loadSelectedModel() {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: Self.selectedModelKey) }
    }

    /// First-run wizard state: shown once (auto-opens until true); re-runnable from the menu. Persisted.
    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: TranscriptionViewModel.hasCompletedOnboardingKey) {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.hasCompletedOnboardingKey) }
    }

    /// Onboarding's "power features" step deep-links Settings here (MCP / Middleware); transient, cleared on read.
    var pendingSettingsTab: SettingsTab?

    /// Per-model on-disk download status, surfaced in Settings and the dropdown.
    var downloadStates: [AsrModel: ModelDownloadState] = [:]

    /// Briefly true right after a copy, so the Copy control can flash "Copied".
    var justCopied = false

    /// True while a Settings shortcut recorder is capturing keys, so the global
    /// ⌥Space hotkey and the stop monitor stand down and let the keys be recorded.
    var isCapturingShortcut = false

    /// Global shortcut that records into a transcription (default bare left ⌥). Persisted.
    var transcriptionShortcut: Hotkey = TranscriptionViewModel.loadHotkey(
        TranscriptionViewModel.transcriptionShortcutKey,
        legacyKey: TranscriptionViewModel.legacyTalkShortcutKey
    ) ?? .transcriptionDefault {
        didSet { Self.saveHotkey(transcriptionShortcut, Self.transcriptionShortcutKey) }
    }

    /// Global shortcut that records and answers with the Ask model, starting a new conversation
    /// (default left ⌥+⌃).
    var askShortcut: Hotkey = TranscriptionViewModel.loadHotkey(TranscriptionViewModel.askShortcutKey) ?? .askDefault {
        didSet { Self.saveHotkey(askShortcut, Self.askShortcutKey) }
    }

    /// Like ``askShortcut`` but *continues* the last conversation (default left ⌥+⌃+⇧, shares Ask's mode).
    var askContinueShortcut: Hotkey =
        TranscriptionViewModel.loadHotkey(TranscriptionViewModel.askContinueShortcutKey) ?? .askContinueDefault {
        didSet { Self.saveHotkey(askContinueShortcut, Self.askContinueShortcutKey) }
    }

    /// Global shortcut that rewrites the frontmost app's selected text (default left ⌥+⇧).
    var rewriteShortcut: Hotkey = TranscriptionViewModel.loadHotkey(TranscriptionViewModel.rewriteShortcutKey) ?? .rewriteDefault {
        didSet { Self.saveHotkey(rewriteShortcut, Self.rewriteShortcutKey) }
    }

    /// Global shortcut that records, translates the transcript into the target language, and
    /// inserts it into the focused field (default left ⌃+⇧). Persisted.
    var translateShortcut: Hotkey = TranscriptionViewModel.loadHotkey(TranscriptionViewModel.translateShortcutKey) ?? .translateDefault {
        didSet { Self.saveHotkey(translateShortcut, Self.translateShortcutKey) }
    }

    /// Global shortcut that finalizes the current recording (default Esc). Persisted.
    var stopShortcut: Hotkey = TranscriptionViewModel.loadHotkey(
        TranscriptionViewModel.stopShortcutKey,
        legacyKey: TranscriptionViewModel.legacyStopShortcutKey
    ) ?? .stopDefault {
        didSet { Self.saveHotkey(stopShortcut, Self.stopShortcutKey) }
    }

    /// Hold-trigger for the radial mode picker (default left ⌥). Persisted.
    var radialShortcut = TranscriptionViewModel.loadHotkey(TranscriptionViewModel.radialShortcutKey) ?? Hotkey.radialDefault {
        didSet { Self.saveHotkey(radialShortcut, Self.radialShortcutKey) }
    }

    /// Whether the radial mode picker is the active launcher (on by default); when on it owns its
    /// trigger and the per-mode chords stand down. Persisted.
    var radialEnabled = TranscriptionViewModel.loadBoolDefaultTrue(TranscriptionViewModel.radialEnabledKey) {
        didSet { UserDefaults.standard.set(radialEnabled, forKey: Self.radialEnabledKey) }
    }

    /// User-assigned wheel direction → mode map (default up = Transcribe, right = Translate, …). Persisted.
    var radialLayout = TranscriptionViewModel.loadRadialLayout() {
        didSet { Self.saveRadialLayout(radialLayout) }
    }

    /// Pop-up dial size as a fraction of full size (0.5...1.0, default 1). Persisted.
    var radialScale = TranscriptionViewModel.loadClamped(TranscriptionViewModel.radialScaleKey, default: 1, min: 0.5, max: 1) {
        didSet { UserDefaults.standard.set(radialScale, forKey: Self.radialScaleKey) }
    }

    /// Whether the transcription shortcut records while held (`hold`) or toggles (`trigger`).
    var transcriptionMode: ActivationMode = TranscriptionViewModel.loadMode(TranscriptionViewModel.transcriptionModeKey) {
        didSet { UserDefaults.standard.set(transcriptionMode.rawValue, forKey: Self.transcriptionModeKey) }
    }

    /// Whether the ask shortcut records while held (`hold`) or toggles (`trigger`).
    var askMode: ActivationMode = TranscriptionViewModel.loadMode(TranscriptionViewModel.askModeKey) {
        didSet { UserDefaults.standard.set(askMode.rawValue, forKey: Self.askModeKey) }
    }

    /// Activation mode for the Ask-continue shortcut, independent of `askMode`. Until the user sets
    /// it, it inherits `askMode` -- the two split out of one setting, so this preserves the prior
    /// "continue uses Ask's mode" behavior on upgrade.
    var askContinueMode: ActivationMode = TranscriptionViewModel.loadMode(
        UserDefaults.standard.object(forKey: TranscriptionViewModel.askContinueModeKey) == nil
            ? TranscriptionViewModel.askModeKey : TranscriptionViewModel.askContinueModeKey
    ) {
        didSet { UserDefaults.standard.set(askContinueMode.rawValue, forKey: Self.askContinueModeKey) }
    }

    /// Whether the rewrite shortcut records while held (`hold`) or toggles (`trigger`).
    var rewriteMode: ActivationMode = TranscriptionViewModel.loadMode(TranscriptionViewModel.rewriteModeKey) {
        didSet { UserDefaults.standard.set(rewriteMode.rawValue, forKey: Self.rewriteModeKey) }
    }

    /// Whether the translate shortcut records while held (`hold`) or toggles (`trigger`).
    var translateMode: ActivationMode = TranscriptionViewModel.loadMode(TranscriptionViewModel.translateModeKey) {
        didSet { UserDefaults.standard.set(translateMode.rawValue, forKey: Self.translateModeKey) }
    }

    /// Push-to-talk start delay in seconds (0 = instant, capped at 3): how long a hold shortcut
    /// must be held before recording begins. Global -- applies to whichever shortcut is in
    /// push-to-talk. Declared after the mode properties so the hands-free migration in `loadMode`
    /// runs before `silenceAutoEndEnabled` reads its (possibly migrated) value.
    var pushToTalkStartDelay: TimeInterval = TranscriptionViewModel.loadClamped(
        TranscriptionViewModel.pushToTalkStartDelayKey, default: 0, min: 0, max: 3
    ) {
        didSet { UserDefaults.standard.set(pushToTalkStartDelay, forKey: Self.pushToTalkStartDelayKey) }
    }

    /// Hold-and-release long-press duration in seconds (0.3...3): how long to hold before recording
    /// toggles on/off. Global.
    var holdReleaseDuration: TimeInterval = TranscriptionViewModel.loadClamped(
        TranscriptionViewModel.holdReleaseDurationKey, default: 0.8, min: 0.3, max: 3
    ) {
        didSet { UserDefaults.standard.set(holdReleaseDuration, forKey: Self.holdReleaseDurationKey) }
    }

    /// Auto-finish a Trigger / Hold & release recording after a pause in speech (replaces the old
    /// standalone hands-free mode). Off by default.
    var silenceAutoEndEnabled = UserDefaults.standard.bool(forKey: TranscriptionViewModel.silenceAutoEndEnabledKey) {
        didSet { UserDefaults.standard.set(silenceAutoEndEnabled, forKey: Self.silenceAutoEndEnabledKey) }
    }

    /// Seconds of post-speech silence before auto-end fires (when `silenceAutoEndEnabled` is on).
    var silenceTimeout: TimeInterval = TranscriptionViewModel.loadClamped(
        TranscriptionViewModel.silenceTimeoutKey, default: SilenceDetector.defaultTimeout, min: 1, max: 5
    ) {
        didSet { UserDefaults.standard.set(silenceTimeout, forKey: Self.silenceTimeoutKey) }
    }

    /// Ask is composed aloud - people pause mid-question to think - so it gets a more patient
    /// silence window than dictation. The shared `silenceTimeout` (kept verbatim for
    /// transcription/translate/rewrite) was finishing Ask in the middle of a sentence; Ask floors
    /// its window here instead. A longer user-set `silenceTimeout` still wins.
    static let askSilenceFloor: TimeInterval = 3.0

    /// When a transcription's manual finish gesture fires, pause (await Stop) or stop (commit now).
    var transcriptionFinishBehavior: TranscriptionFinishBehavior = TranscriptionViewModel.loadFinishBehavior() {
        didSet { UserDefaults.standard.set(transcriptionFinishBehavior.rawValue, forKey: Self.transcriptionFinishBehaviorKey) }
    }

    /// The raw shortcut that started the current session, with `.askContinue` preserved so a
    /// continue session can use its own activation mode and status line. Set by which shortcut
    /// started the recording.
    private(set) var activeRawIntent: RecordIntent = .transcription

    /// Whether the app is trusted for Accessibility (needed for global, unfocused shortcuts).
    /// Stored so the Settings banner can react; refresh with ``refreshAccessibilityTrust()`` (set
    /// only there - it's split into ``TranscriptionViewModel+Permissions``).
    var accessibilityTrusted = AXIsProcessTrusted()

    /// Whether microphone access is granted. Drives the onboarding "grant" row; refresh with
    /// ``refreshMicPermission()``, request the prompt with ``requestMicrophonePermission()``.
    var micPermissionGranted = MicCapture.permissionGranted()

    /// Setting: when a recording finishes, copy its transcript automatically.
    /// Persisted in `UserDefaults`.
    var autoCopyOnFinish = UserDefaults.standard.bool(forKey: TranscriptionViewModel.autoCopyKey) {
        didSet { UserDefaults.standard.set(autoCopyOnFinish, forKey: Self.autoCopyKey) }
    }

    /// How voice modes (Transcription, Rewrite, Translate) appear while recording. Persisted.
    var recordingPresentation: RecordingPresentation = TranscriptionViewModel.loadRecordingPresentation() {
        didSet {
            UserDefaults.standard.set(recordingPresentation.rawValue, forKey: Self.recordingPresentationKey)
            if !UserDefaults.standard.bool(forKey: "mispher.askPresentationIndependent") {
                askPresentation = recordingPresentation
            }
        }
    }

    var askPresentation: RecordingPresentation = TranscriptionViewModel.loadAskPresentation() {
        didSet { UserDefaults.standard.set(askPresentation.rawValue, forKey: Self.askPresentationKey) }
    }

    /// Setting (floating presentation only): drop the floating card next to the mouse pointer each
    /// time recording starts, instead of re-using its centred / last-dragged position. Off by
    /// default. Persisted.
    var floatingFollowsPointer = UserDefaults.standard.bool(forKey: TranscriptionViewModel.floatingFollowsPointerKey) {
        didSet { UserDefaults.standard.set(floatingFollowsPointer, forKey: Self.floatingFollowsPointerKey) }
    }

    /// Setting: the microphone used for recording, by Core Audio device UID. Empty string means
    /// "System Default" (no override). Persisted; read by ``MicCapture`` on each ``start()``.
    var selectedInputDeviceUID = UserDefaults.standard.string(forKey: TranscriptionViewModel.selectedInputDeviceKey) ?? "" {
        didSet { UserDefaults.standard.set(selectedInputDeviceUID, forKey: Self.selectedInputDeviceKey) }
    }

    /// Input devices offered in the Settings / menu-bar / onboarding pickers. Refreshed on demand
    /// (devices come and go) via ``refreshInputDevices()`` rather than enumerated on every read.
    /// Set only there (in ``TranscriptionViewModel+Permissions``).
    var availableInputDevices: [AudioInputDevice] = []

    /// Setting: language hint for the Nemotron multilingual model. Persisted.
    var nemotronLanguage =
        UserDefaults.standard.string(forKey: TranscriptionViewModel.nemotronLanguageKey) ?? "auto" {
        didSet { UserDefaults.standard.set(nemotronLanguage, forKey: Self.nemotronLanguageKey) }
    }

    /// Master switch for the whole Translation feature (Settings ▸ Translate "Enable Translation").
    /// Default on; when off the Translate shortcut is hidden and never fires, "Always translate
    /// transcription" (``translationEnabled``) is hidden and ignored, and the HUD translate picker is
    /// gone -- no translation happens anywhere. Turning it off frees the translation model.
    var translateEnabled = TranscriptionViewModel.loadBoolDefaultTrue(TranscriptionViewModel.translateEnabledKey) {
        didSet {
            UserDefaults.standard.set(translateEnabled, forKey: Self.translateEnabledKey)
            guard translateEnabled != oldValue else { return }
            // Keep the translation model warm only while translation can actually run.
            mlxModels?.setTranslationModel(translateEnabled && translationEnabled ? translationModelId : nil)
        }
    }

    /// Setting: translate the finished transcript into `translationTargetLanguage`
    /// with the chosen on-device instruct model, shown beneath the original. Persisted;
    /// also toggled from the HUD header. Gated by ``translateEnabled``. Turning it on
    /// warms up (downloads/loads) the model so it's ready by stop time.
    var translationEnabled = TranscriptionViewModel.loadTranslationEnabled() {
        didSet {
            UserDefaults.standard.set(translationEnabled, forKey: Self.translationEnabledKey)
            guard translationEnabled != oldValue else { return }
            if translateEnabled, translationEnabled {
                mlxModels?.setTranslationModel(translationModelId)
            } else {
                mlxModels?.setTranslationModel(nil)
            }
        }
    }

    /// Setting: which on-device instruct model performs the translation. Always set
    /// (so the choice survives turning translation off); used only when enabled.
    var translationModelId =
        UserDefaults.standard.string(forKey: TranscriptionViewModel.translationModelKey)
            ?? TranscriptionViewModel.defaultTranslationModelId {
        didSet {
            UserDefaults.standard.set(translationModelId, forKey: Self.translationModelKey)
            guard translationModelId != oldValue else { return }
            // Switch models live while translation is on; otherwise just remember it.
            if translateEnabled, translationEnabled { mlxModels?.setTranslationModel(translationModelId) }
            // Keep the target language valid for the new model (every set includes English).
            if !translationLanguages.contains(translationTargetLanguage) {
                translationTargetLanguage = translationLanguages.first ?? .english
            }
        }
    }

    /// Setting: the editable instruction block sent to the translation model (Settings ▸ Translate).
    /// The target language and input text are substituted at ``TranslationPrompt/languageToken`` /
    /// ``TranslationPrompt/inputToken``. Blank falls back to ``TranslationPrompt/defaultInstructions``.
    /// Persisted; shared by the translate shortcut and the header translate toggle.
    var translationPrompt: String = TranscriptionViewModel.loadTranslationPrompt() {
        didSet { UserDefaults.standard.set(translationPrompt, forKey: Self.translationPromptKey) }
    }

    /// Setting: which on-device instruct model performs AI dictation cleanup. Independent of
    /// the translation and rewrite models. Persisted (migrates from the old combined setting).
    var cleanupModelId =
        UserDefaults.standard.string(forKey: TranscriptionViewModel.cleanupModelKey)
            ?? UserDefaults.standard.string(forKey: TranscriptionViewModel.assistModelKey)
            ?? TranscriptionViewModel.defaultTranslationModelId {
        didSet {
            UserDefaults.standard.set(cleanupModelId, forKey: Self.cleanupModelKey)
            guard cleanupModelId != oldValue else { return }
            // Re-point the warmed cleanup model when AI cleanup is on.
            if dictationEnabled { mlxModels?.setCleanupModel(cleanupModelId) }
        }
    }

    /// Setting: the editable cleanup instruction block (Settings ▸ Dictation). Persisted.
    var cleanupPrompt = TranscriptionViewModel.loadCleanupPrompt() {
        didSet { UserDefaults.standard.set(cleanupPrompt, forKey: Self.cleanupPromptKey) }
    }

    /// Setting: which on-device instruct model rewrites selected text by voice. Independent of
    /// the translation and cleanup models; loaded on demand. Persisted (migrates from the old
    /// combined setting).
    var rewriteModelId =
        UserDefaults.standard.string(forKey: TranscriptionViewModel.rewriteModelKey)
            ?? UserDefaults.standard.string(forKey: TranscriptionViewModel.assistModelKey)
            ?? TranscriptionViewModel.defaultTranslationModelId {
        didSet { UserDefaults.standard.set(rewriteModelId, forKey: Self.rewriteModelKey) }
    }

    /// Master switch for the Rewrite feature. Default on; when off the Rewrite shortcut is hidden in
    /// Settings/onboarding and never fires (see ``shortcutConfig``).
    var rewriteEnabled = TranscriptionViewModel.loadBoolDefaultTrue(TranscriptionViewModel.rewriteEnabledKey) {
        didSet { UserDefaults.standard.set(rewriteEnabled, forKey: Self.rewriteEnabledKey) }
    }

    /// Setting: the editable instruction block sent to the rewrite model (Settings ▸ Rewrite).
    /// The selected text is appended automatically, so an edit here can't break the selection
    /// injection. Blank falls back to ``RewritePrompt/defaultInstructions``. Persisted.
    var rewritePrompt: String =
        UserDefaults.standard.string(forKey: TranscriptionViewModel.rewritePromptKey)
            ?? RewritePrompt.defaultInstructions {
        didSet { UserDefaults.standard.set(rewritePrompt, forKey: Self.rewritePromptKey) }
    }

    /// Setting: the language the transcript is translated into. Persisted.
    var translationTargetLanguage = TranscriptionViewModel.loadTranslationLanguage() {
        didSet {
            UserDefaults.standard.set(translationTargetLanguage.rawValue, forKey: Self.translationTargetKey)
        }
    }

    /// Master switch for the Dictation feature (Settings ▸ Dictation "Enable Dictation"): when on,
    /// the finished transcript is sent to an on-device model for AI cleanup (punctuation,
    /// capitalization, filler/number/abbreviation fixes, dictation commands) before it's shown/copied.
    /// Transcription intent only; the transcribe shortcut itself is never gated by this. Default off
    /// (migrates the legacy "Clean up dictation with AI" value). Turning it on warms the cleanup
    /// model so it's ready by stop time. Persisted.
    var dictationEnabled = TranscriptionViewModel.loadDictationEnabled() {
        didSet {
            UserDefaults.standard.set(dictationEnabled, forKey: Self.dictationEnabledKey)
            guard dictationEnabled != oldValue else { return }
            mlxModels?.setCleanupModel(dictationEnabled ? cleanupModelId : nil)
        }
    }

    /// Setting: deterministically strip standalone filler words ("um", "uh", …) from the
    /// finished transcript. Independent of — and cheaper than — the AI cleanup. Persisted.
    var removeFillerWords = UserDefaults.standard.bool(forKey: TranscriptionViewModel.removeFillerWordsKey) {
        didSet { UserDefaults.standard.set(removeFillerWords, forKey: Self.removeFillerWordsKey) }
    }

    /// Setting: user-defined find→replace rules applied to the finished transcript (e.g.
    /// force a spelling, expand a term). Persisted as JSON.
    var customDictionary: [CustomDictionaryEntry] = TranscriptionViewModel.loadCustomDictionary() {
        didSet { Self.saveCustomDictionary(customDictionary) }
    }

    /// True while the on-device AI cleanup pass is running, to show "Cleaning up…".
    var isCleaningUp = false

    /// Developer setting: append every agent message (human/assistant/tool, in order) to
    /// a JSONL file per thread under `agentLogDirectory`, for later analysis. Persisted.
    var logAgentMessages = UserDefaults.standard.bool(forKey: AgentLogSettings.enabledKey) {
        didSet { UserDefaults.standard.set(logAgentMessages, forKey: AgentLogSettings.enabledKey) }
    }

    /// Developer setting: directory the agent message log writes to (empty = a default
    /// under Application Support). Persisted.
    var agentLogDirectory =
        UserDefaults.standard.string(forKey: AgentLogSettings.directoryKey) ?? "" {
        didSet { UserDefaults.standard.set(agentLogDirectory, forKey: AgentLogSettings.directoryKey) }
    }

    /// MCP servers the agent can load tools from. Persisted as JSON in `UserDefaults`;
    /// build a `MultiServerMCPClient(configs:)` from this to hand MCP tools to an agent.
    var mcpServers: [MCPServerConfig] = TranscriptionViewModel.loadMCPServers() {
        didSet { Self.saveMCPServers(mcpServers); pushAgentToolConfig() }
    }

    /// The deep-agent middleware/tool activation + Approve/Ask/Deny choices (Middleware Settings
    /// tab). Persisted as JSON in `UserDefaults`; a fresh value keeps the agent's built-in behavior.
    var agentToolPolicy: AgentToolPolicy = TranscriptionViewModel.loadAgentToolPolicy() {
        didSet { Self.saveAgentToolPolicy(agentToolPolicy); pushAgentToolConfig() }
    }

    /// On-device model manager backing translation and Ask (set in `MispherApp`).
    @ObservationIgnored var mlxModels: MlxModelManager? {
        // `deepAgent.manager =` seeds the manager with the persisted DeepAgent model + idle choices.
        didSet { pushAgentToolConfig(); deepAgent.manager = mlxModels }
    }

    /// The MLX instruct model translation defaults to (and migrates to).
    static let defaultTranslationModelId = "LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16"

    /// Shared mic capture. Internal (not private) so ``TranscriptionViewModel+Permissions`` can
    /// request authorization through it.
    let mic = MicCapture()
    /// Hands-free auto-stop: watches the mic level and finalizes after a post-speech silence.
    private let silenceDetector = SilenceDetector()
    private var engine: (any TranscriptionEngine)?
    private var consumerTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<AudioSamples>.Continuation?

    /// Qwen3-ASR `llama-server` endpoint. `127.0.0.1` (not `localhost`) so we hit
    /// the IPv4-bound server directly and skip the IPv6 `::1` attempt that just
    /// logs a "connection refused" before falling back.
    private let qwenServerURL = URL(string: "http://127.0.0.1:8123")!

    /// How to launch the Qwen3-ASR server if it isn't already running.
    private var qwenServerSpec: LlamaServerManager.Spec {
        LlamaServerManager.Spec(
            role: "Qwen3-ASR server",
            baseURL: qwenServerURL,
            arguments: [
                "-hf", "ggml-org/Qwen3-ASR-1.7B-GGUF",
                "-b", "1024", "-ub", "1024",
                "--host", "127.0.0.1", "--port", "\(qwenServerURL.port ?? 8123)"
            ]
        )
    }

    // MARK: - Derived UI state

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }

    /// A capture session is open (recording or paused) — the engine is live.
    var isSessionActive: Bool { isRecording || isPaused }

    var isBusy: Bool {
        switch state {
        case .preparing, .finalizing: return true
        default: return false
        }
    }

    /// Chat is the type-only surface for the on-device DeepAgent, so it can only be *entered* when
    /// Ask is enabled and no capture session is open or in-flight. (Leaving chat is always allowed.)
    var canEnterChat: Bool { askEnabled && !isSessionActive && !isBusy }

    /// The primary control (start / pause / resume) is available.
    var canPrimary: Bool {
        switch state {
        case .preparing, .finalizing: return false
        default: return true
        }
    }

    /// Stop is available only while a session is open.
    var canStop: Bool { isSessionActive }

    /// The compact recording overlay shows during these phases -- including the on-device AI
    /// cleanup pass (transcription), rewrite generation, and the translation pass, all of which
    /// run after the state has already returned to idle.
    var isOverlayPhase: Bool {
        isSessionActive || isBusy || isCleaningUp || isRewriting || isTranslating || askOverlaySessionActive
    }

    /// Whether `model` can be activated from the dropdown right now (downloaded,
    /// or server-based like Qwen).
    func canActivate(_ model: AsrModel) -> Bool {
        model.requiresLocalServer || (downloadStates[model]?.isDownloaded ?? false)
    }

    /// Whether a prepared engine is currently loaded (false right after deleting
    /// the active model, or on a fresh launch with nothing downloaded).
    var hasEngine: Bool { engine != nil }

    // MARK: - Lifecycle

    func onAppear() {
        Task {
            await refreshDownloadStates()
            await activateSelectedIfPossible()
        }
    }

    // MARK: - Model selection

    /// Re-check on-disk status for every model. Cheap file-existence checks.
    func refreshDownloadStates() async {
        for model in AsrModel.allCases {
            if model.requiresLocalServer {
                downloadStates[model] = .downloaded // server-based; always available
            } else if downloadStates[model]?.isDownloading == true {
                continue // don't clobber an in-flight download
            } else {
                downloadStates[model] = ModelStore.isDownloaded(model) ? .downloaded : .notDownloaded
            }
        }
    }

    /// Prepare the selected model if available; otherwise guide the user to Settings.
    private func activateSelectedIfPossible() async {
        if canActivate(selectedModel) {
            await selectEngine(selectedModel)
        } else {
            engine = nil
            state = .idle
            statusMessage = "No model downloaded - open Settings to download one."
        }
    }

    /// Switch the active model from the dropdown. Only downloaded/available
    /// models can be activated (the UI greys out the rest).
    func selectModel(_ model: AsrModel) {
        guard model != selectedModel, !isSessionActive else { return }
        guard canActivate(model) else {
            statusMessage = "\(model.displayName) isn't downloaded yet - get it in Settings."
            return
        }
        selectedModel = model
        Task { await selectEngine(model) }
    }

    private func selectEngine(_ model: AsrModel) async {
        guard !isSessionActive else { return }
        state = .preparing
        statusMessage = "Preparing \(model.displayName)…"

        // Server-backed models need their `llama-server` up; start it on demand.
        if model.requiresLocalServer {
            do {
                try await LlamaServerManager.shared.ensureReachable(qwenServerSpec) { [weak self] message in
                    Task { @MainActor in self?.statusMessage = message }
                }
            } catch {
                engine = nil
                let message = Self.describe(error)
                state = .error(message)
                statusMessage = message
                return
            }
        }

        let newEngine = makeEngine(for: model)
        let status: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.statusMessage = message }
        }

        do {
            try await newEngine.prepare(status: status)
            engine = newEngine
            state = .idle
            statusMessage = model.readyMessage
        } catch {
            engine = nil
            let message = Self.describe(error)
            state = .error(message)
            statusMessage = message
        }
    }

    private func makeEngine(for model: AsrModel) -> any TranscriptionEngine {
        switch model {
        case .parakeetEouEnglish: return ParakeetEngine()
        case .nemotronMultilingual: return NemotronMultilingualEngine(language: nemotronLanguage)
        case .parakeetTdtV3: return BatchReprocessEngine(backend: ParakeetTdtBackend())
        case .parakeetCtcInt8: return BatchReprocessEngine(backend: CtcZhCnBackend(useInt8: true))
        case .parakeetCtcFp32: return BatchReprocessEngine(backend: CtcZhCnBackend(useInt8: false))
        case .qwenChinese: return QwenEngine(baseURL: qwenServerURL)
        }
    }

    // MARK: - Model downloads

    func downloadModel(_ model: AsrModel) {
        guard model.isDownloadable, downloadStates[model]?.isDownloading != true else { return }
        // CTC int8/fp32 share one bundle — move every sibling row together.
        let siblings = model.downloadSiblings
        for sibling in siblings { downloadStates[sibling] = .downloading(0) }

        Task {
            let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    for sibling in siblings where self.downloadStates[sibling]?.isDownloading == true {
                        self.downloadStates[sibling] = .downloading(fraction)
                    }
                }
            }
            do {
                try await ModelStore.download(model, progress: onProgress)
                for sibling in siblings { downloadStates[sibling] = .downloaded }
                // First model on a fresh launch: activate it so the app is usable.
                if engine == nil, !isSessionActive {
                    selectedModel = model
                    await selectEngine(model)
                }
            } catch {
                let message = Self.describe(error)
                for sibling in siblings { downloadStates[sibling] = .failed(message) }
            }
        }
    }

    /// Change the Nemotron language hint; re-prepares it if it's the active model.
    func setNemotronLanguage(_ code: String) {
        guard code != nemotronLanguage else { return }
        nemotronLanguage = code
        if selectedModel == .nemotronMultilingual, !isSessionActive,
           canActivate(.nemotronMultilingual) {
            Task { await selectEngine(.nemotronMultilingual) }
        }
    }

    func deleteModel(_ model: AsrModel) {
        guard model.isDownloadable, !isSessionActive else { return }
        do {
            try ModelStore.delete(model)
            // Deleting the shared bundle clears every sibling row (CTC int8/fp32).
            let siblings = model.downloadSiblings
            for sibling in siblings { downloadStates[sibling] = .notDownloaded }
            if siblings.contains(selectedModel) {
                engine = nil
                state = .idle
                statusMessage = "Model deleted - download or pick another model."
            }
        } catch {
            statusMessage = "Couldn't delete \(model.displayName): \(Self.describe(error))"
        }
    }

    // MARK: - Recording

    /// Spacebar / primary button: start when idle, pause when recording, resume
    /// when paused.
    func primaryAction() {
        switch state {
        case .idle, .error: Task { await start() }
        case .recording: Task { await pause() }
        case .paused: Task { await resume() }
        case .preparing, .finalizing: break
        }
    }

    /// Stop button: finalize the session (from recording or paused).
    func stopRecording() {
        guard isSessionActive else { return }
        Task { await stop() }
    }

    /// Chat composer mic: dictate speech into the chat field. Forces a flagged `.transcription` session
    /// so capture skips the frontmost field and finalize routes the transcript into the composer.
    func startComposerDictation() {
        guard !isSessionActive else { return }
        composerDictationActive = true
        activeRawIntent = .transcription
        beginDictationCapture() // no-op while composerDictationActive (no external target, no HUD float)
        Task { await start() }
    }

    func stopComposerDictation() { stopRecording() }

    /// Silence auto-end: the mic went quiet after speech, so finalize as if Stop were pressed.
    /// Guarded to a still-recording session whose mode opted into silence auto-end so it can't race
    /// a manual stop. Always commits, regardless of `transcriptionFinishBehavior`.
    func autoStopFromSilence() {
        guard state == .recording,
              Self.shouldArmSilence(enabled: silenceAutoEndEnabled, mode: activeMode) else { return }
        Task { await stop() }
    }

    // MARK: - Shortcut gestures (Hold / Trigger / Stop)

    /// True while a Hold shortcut chord is physically held.
    private var chordHeld = false

    /// Set by ``startRadialMode(_:)`` so the next ``start()`` latches ``sessionFromRadial`` (one-shot,
    /// so every non-radial start stays non-radial).
    var pendingRadialLaunch = false

    /// Whether this session came from the radial picker (commits on release, so it finishes Trigger-style).
    private(set) var sessionFromRadial = false

    /// Hold-mode press for `intent`: bring the app forward and begin (or resume) capture.
    /// For `rewrite`, first grab the frontmost app's selection (and *don't* steal focus, so the
    /// selection stays put and the result can be written back).
    func shortcutPressed(_ rawIntent: RecordIntent) {
        let intent = rawIntent.asActiveIntent
        // Global shortcuts fire regardless of the HUD chat being open or a field being edited:
        // every intent has its own overlay/notch surface, so they stay available alongside the
        // typed HUD chat.
        // Ignore a hold-press whose intent differs from the active session — its release acts
        // on `activeIntent`, so it would otherwise pause/stop (or resume) the wrong session.
        if isSessionActive, intent != activeIntent { return }
        // Don't start a new Ask turn while the current one is still answering (the chat backend
        // would drop it); the overlay keeps showing the in-flight answer.
        if isAskTurnBusy(intent) { return }
        if intent == .rewrite, !isSessionActive, !beginRewriteCapture() { return }
        // Translate inserts its result into the focused field like dictation, so capture the target.
        if intent == .transcription || intent == .translate, !isSessionActive { beginDictationCapture() }
        chordHeld = true
        if !isSessionActive { activeRawIntent = rawIntent }
        // Ask activation: a roomier overlay form runs Ask as a voice conversation in the overlay
        // (keeps the user's app focused); the notch/main window bring Mispher forward (HUD answer).
        // Transcription and Rewrite write back into the user's app, so they only float the HUD
        // (showHudForFeedback) and never steal focus — keeping the target field's caret put.
        if intent == .ask { activateAsk(fresh: rawIntent == .ask && !isSessionActive) }
        switch state {
        case .idle, .error:
            Task {
                await start()
                // If the chord was let go during preparation, end the segment now.
                if !chordHeld { endSegment() }
            }
        case .paused:
            Task { await resume() }
        case .recording, .preparing, .finalizing:
            break
        }
    }

    /// Hold-mode release: ask intent finalizes (and answers); transcription pauses so the
    /// next press can add more speech to the same transcript.
    func shortcutReleased(_ intent: RecordIntent) {
        // Ignore the release of a chord whose intent isn't the active session's (its press was
        // ignored too) — otherwise it would clear chordHeld and end the *active* session.
        guard intent.asActiveIntent == activeIntent else { return }
        chordHeld = false
        guard state == .recording else { return }
        endSegment()
    }

    /// Trigger-mode tap: first tap starts a session for `intent`; a second tap of the same
    /// intent finalizes it.
    func shortcutTapped(_ rawIntent: RecordIntent) {
        let intent = rawIntent.asActiveIntent
        // Global shortcuts fire regardless of the HUD chat being open or a field being edited
        // (see `shortcutPressed`).
        if isAskTurnBusy(intent) { return }
        if isSessionActive {
            guard activeIntent == intent else { return }
            // Transcription honors the pause/stop finish setting: while recording, finish (pause or
            // stop); while paused (pause mode), a tap resumes so the user can add more before Stop.
            if intent == .transcription {
                switch state {
                case .recording: endSegment()
                case .paused: Task { await resume() }
                default: break
                }
            } else {
                stopRecording()
            }
            return
        }
        switch state {
        case .idle, .error:
            if intent == .rewrite, !beginRewriteCapture() { return }
            if intent == .transcription || intent == .translate { beginDictationCapture() }
            activeRawIntent = rawIntent
            if intent == .ask { activateAsk(fresh: rawIntent == .ask) }
            Task { await start() }
        case .recording, .paused, .preparing, .finalizing:
            break
        }
    }

    /// A modifier-chord hold that turned out to be normal modifier+key usage (e.g. ⌥e):
    /// discard the just-started recording without finalizing.
    func shortcutCancelled(_ intent: RecordIntent) {
        guard isSessionActive, activeIntent == intent.asActiveIntent else { return }
        chordHeld = false
        Task { await cancelRecording() }
    }

    /// The Stop shortcut (Esc): stop a recording, else a streaming Ask answer, else dismiss the chat.
    func stopPressed() {
        if isSessionActive { Task { await stop() }; return }
        if let id = mlxModels?.activeConversationId, mlxModels?.isGenerating(id) == true { mlxModels?.cancelChat(id); return }
        if askOverlaySessionActive { dismissAskOverlay() }
    }

    private func endSegment() {
        // Transcription honors the finish setting (pause/stop); Ask, Rewrite, Translate always finalize.
        // A radial-launched session always commits -- pause-to-add-more is a held-chord-only affordance.
        let behavior: TranscriptionFinishBehavior = sessionFromRadial ? .stop : transcriptionFinishBehavior
        switch Self.finishAction(intent: activeIntent, behavior: behavior) {
        case .pause: Task { await pause() }
        case .stop: Task { await stop() }
        }
    }

    private func start() async {
        guard let engine else {
            statusMessage = "Engine not ready - pick an engine first."
            return
        }

        state = .preparing
        statusMessage = "Starting…"
        // Latch (one-shot) whether this is a radial launch, before silence arming reads `activeMode`.
        sessionFromRadial = pendingRadialLaunch
        pendingRadialLaunch = false

        let granted = await mic.requestPermission()
        guard granted else {
            let message = AppError.micPermissionDenied.localizedDescription
            state = .error(message)
            statusMessage = message
            return
        }

        let (stream, continuation) = AsyncStream<AudioSamples>.makeStream()
        streamContinuation = continuation

        let partial: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.partialText = text }
        }

        do {
            try await engine.startSession(partial: partial)
        } catch {
            let message = Self.describe(error)
            state = .error(message)
            statusMessage = message
            return
        }

        // Silence auto-end (Hold & release always; Trigger when enabled): finish once the user stops
        // speaking, else stand the detector down. `armedForSilence()` also logs the decision.
        if armedForSilence() {
            await silenceDetector.arm(timeout: effectiveSilenceTimeout) { [weak self] in
                Task { @MainActor in self?.autoStopFromSilence() }
            }
        } else {
            await silenceDetector.disarm()
        }

        // Single ordered consumer: preserves capture order and applies backpressure. It also
        // feeds the silence detector (a no-op unless armed) so hands-free mode can auto-finish.
        let activeEngine = engine
        let detector = silenceDetector
        consumerTask = Task.detached {
            for await samples in stream {
                await activeEngine.append(samples)
                await detector.ingest(samples)
            }
        }

        do {
            try mic.start(deviceUID: selectedInputDeviceUID) { samples in continuation.yield(samples) }
        } catch {
            continuation.finish()
            let message = Self.describe(error)
            state = .error(message)
            statusMessage = message
            return
        }

        partialText = ""
        finalText = ""
        translatedText = ""
        isTranslating = false
        askReplyText = ""
        askTimeline = []
        askStreamingText = ""
        isAsking = false
        rewriteResultText = ""
        isRewriting = false
        isCleaningUp = false
        state = .recording
        statusMessage = recordingStatus
    }

    /// Pause capture but keep the engine session open so it can resume. The
    /// audio stream and consumer stay alive; only the mic is stopped.
    private func pause() async {
        guard state == .recording else { return }
        mic.stop()
        await silenceDetector.reset()
        state = .paused
        let resume: String
        switch activeMode {
        case .hold: resume = "hold \(transcriptionShortcut.display) to continue"
        case .trigger: resume = "tap \(transcriptionShortcut.display) to continue"
        case .holdRelease: resume = "long-press \(transcriptionShortcut.display) to continue"
        }
        statusMessage = "Paused - \(resume) · \(stopShortcut.display) to stop."
    }

    /// Resume a paused session: restart the mic feeding the same stream.
    private func resume() async {
        guard state == .paused, let continuation = streamContinuation else { return }
        do {
            try mic.start(deviceUID: selectedInputDeviceUID) { samples in continuation.yield(samples) }
        } catch {
            let message = Self.describe(error)
            state = .error(message)
            statusMessage = message
            return
        }
        await silenceDetector.reset() // restart the hands-free silence count after a pause
        state = .recording
        statusMessage = recordingStatus
    }

    private func stop() async {
        state = .finalizing
        statusMessage = "Finalizing…"

        mic.stop()
        await silenceDetector.disarm()
        streamContinuation?.finish()
        streamContinuation = nil
        await consumerTask?.value
        consumerTask = nil

        do {
            let raw = try await engine?.finishSession() ?? ""
            let captured = raw.isEmpty ? partialText : raw

            // Rewrite intent: the transcript is an *instruction* for the selected text, not
            // dictation output — keep it verbatim (no post-processing) and apply it to the
            // selection captured when the session began.
            if activeIntent == .rewrite {
                finalText = captured
                partialText = ""
                state = .idle
                // Consume the capture now (and clear it) so a new session started while the
                // rewrite is generating can't have its own capture clobbered.
                let selection = rewriteSelection
                let element = rewriteTargetElement
                let targetPID = rewriteTargetPID
                rewriteSelection = ""
                rewriteTargetElement = nil
                rewriteTargetPID = nil
                await runRewrite(instruction: captured, selection: selection, element: element, targetPID: targetPID)
                return
            }

            var processed = captured

            // Deterministic post-processing (instant): filler removal (T5) then the custom
            // find→replace dictionary (T2). Applied to transcription and ask transcripts (rewrite
            // returned above) so the cleaned text flows into display, clipboard, translation, and
            // the Ask agent.
            if removeFillerWords { processed = TranscriptPostProcessing.stripFillers(processed) }
            processed = TranscriptPostProcessing.applyDictionary(processed, entries: customDictionary)

            finalText = processed
            partialText = ""
            state = .idle
            statusMessage = selectedModel.readyMessage

            // Composer dictation goes to the chat field: commit the raw transcript, let ChatView mirror it.
            if composerDictationActive, activeIntent == .transcription {
                composerDictationActive = false
                return
            }

            // On-device AI cleanup (T3): transcription intent only, best-effort. Runs after
            // the deterministic steps and replaces finalText when it succeeds; the custom
            // dictionary is re-applied so the user's explicit replacements still win over an
            // AI rephrase. On failure (e.g. model not downloaded) the deterministic text stands.
            if dictationEnabled, activeIntent == .transcription, !processed.isEmpty,
               let mlx = mlxModels {
                isCleaningUp = true
                statusMessage = "Cleaning up…"
                let cleaned = await mlx.cleanup(processed, prompt: cleanupPrompt, modelId: cleanupModelId)
                isCleaningUp = false
                // Only apply if nothing new started while we waited. `isSessionActive` is false
                // during a new session's `.preparing`, so require the run to still be idle on the
                // same transcription transcript.
                guard state == .idle, activeIntent == .transcription, finalText == processed else { return }
                if let cleaned, !cleaned.isEmpty {
                    finalText = TranscriptPostProcessing.applyDictionary(cleaned, entries: customDictionary)
                }
                statusMessage = selectedModel.readyMessage
            }

            SystemTextAccess.tlog("finalize: intent=\(activeIntent) translate=\(translationEnabled) finalLen=\(finalText.count)")
            // Auto-copy the transcript, except for the translate intent — its translated output is
            // copied (and inserted) by `translateAndInsert`, so copying the source here would be wrong.
            if autoCopyOnFinish, activeIntent != .translate, !finalText.isEmpty {
                writeToPasteboard(finalText)
                flashCopied()
            }
            // Auto-translate the dictation only when the Translation feature is on *and* "Always
            // translate transcription" is set; the master switch makes a stale sub-toggle inert.
            let autoTranslate = translateEnabled && translationEnabled
            // Hotkey dictation: type the transcript into the field the user was in, then hide the
            // HUD. Only the plain (untranslated) transcription path — Ask answers in the HUD, and a
            // translation has its own display, so neither auto-inserts. (Composer dictation already
            // returned above.)
            if activeIntent == .transcription, !autoTranslate, !finalText.isEmpty {
                finishDictationInsert(finalText)
            }
            if autoTranslate, activeIntent == .transcription, !finalText.isEmpty {
                await translateFinal()
            }
            // Translate intent: translate the spoken transcript, then insert it like dictation.
            // If Translation was switched off mid-session, fall back to inserting the raw transcript
            // so the speech isn't lost (and nothing is sent to the translation model).
            if activeIntent == .translate, !finalText.isEmpty {
                if translateEnabled {
                    await translateAndInsert()
                } else {
                    finishDictationInsert(finalText)
                }
            }
            if activeIntent == .ask, !finalText.isEmpty {
                if askModelId == nil {
                    statusMessage = "Enable Ask in Settings to answer."
                } else if askOverlaySessionActive {
                    // Roomier overlay form: add a turn to the multi-turn conversation shown there.
                    await askOverlayTurn(prompt: finalText)
                } else {
                    // Notch / main window: the single-turn HUD answer.
                    await askLocalModel()
                }
            }
        } catch {
            let message = Self.describe(error)
            state = .error(message)
            statusMessage = message
        }
    }

    /// Discard the current recording without finalizing (no transcript, no ask). Used when a
    /// bare-modifier hold turned out to be normal modifier+key usage.
    private func cancelRecording() async {
        guard isSessionActive else { return }
        mic.stop()
        await silenceDetector.disarm()
        streamContinuation?.finish()
        streamContinuation = nil
        await consumerTask?.value
        consumerTask = nil
        _ = try? await engine?.finishSession()
        partialText = ""
        finalText = ""
        rewriteSelection = ""
        rewriteTargetElement = nil
        rewriteTargetPID = nil
        dictationTargetElement = nil
        dictationTargetPID = nil
        composerDictationActive = false
        state = .idle
        statusMessage = selectedModel.readyMessage
    }

    // Helpers are split into extensions to keep this file within the length limit: persistence in
    // `+Persistence`, shortcuts in `+ShortcutSupport`, translation in `+Translation`, errors in `+Errors`.
}
