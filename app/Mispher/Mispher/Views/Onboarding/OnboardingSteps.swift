import AppKit
import DeepAgents
import DeepAgentsMLX
import SwiftUI

// The individual steps of the first-run wizard (see ``OnboardingView``). Each step writes straight
// to ``TranscriptionViewModel`` (which persists live), and reuses the Settings design system -
// `SettingsCard`, `SettingsRow`, `GlassOptionPicker`, `GlassDropdown`, `KeyRecorderField` - so the
// wizard reads as a guided slice of Settings rather than a parallel UI.

// MARK: - Shared helpers

/// A short explanatory line at the top of a step.
private struct OnboardingNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.sans(11.5))
            .foregroundStyle(Palette.fg2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A boxed informational callout with an "i" icon - used for the "you can change this later in
/// Settings" hints shown under a feature once it's switched on.
private struct OnboardingInfoBox: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.accent)
                .padding(.top, 1)
            Text(text)
                .font(.sans(11.5))
                .foregroundStyle(Palette.fg1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.accentSoft))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.22), lineWidth: 0.5)
        )
    }
}

/// The glass dropdown for picking an on-device language model (rewrite / translate). Mirrors
/// ``SettingsView``'s `modelMenu`: the pill shows the compact short name, the list shows full rows.
@MainActor private func onboardingModelMenu(
    current: String, shortName: String?, select: @escaping (String) -> Void
) -> some View {
    VStack(alignment: .center, spacing: 5) {
        GlassDropdown(
            options: MlxModel.languageCatalog.map { (value: $0.id, label: "\($0.displayName) · \($0.detail)") },
            selection: Binding(get: { current }, set: { select($0) }),
            maxWidth: 240,
            displayLabel: shortName ?? "Select…"
        )
        ModelMemoryHint(modelId: current)
    }
}

/// A labelled card row pairing the shortcut recorder with its activation-mode control - the Settings
/// "Shortcuts" tab pattern, trimmed to a single shortcut and laid out vertically so the wide
/// controls get their own line.
private struct OnboardingShortcutRow: View {
    let title: String
    let subtitle: String
    let hotkey: Hotkey
    var allowsModifierOnly = true
    let onChange: (Hotkey) -> Void
    let mode: Binding<ActivationMode>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sans(12.5, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text(subtitle)
                    .font(.sans(11))
                    .foregroundStyle(Palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                KeyRecorderField(hotkey: hotkey, allowsModifierOnly: allowsModifierOnly, onChange: onChange)
                GlassSegmented(
                    options: [(ActivationMode.hold, "Push to talk"), (.trigger, "Trigger"), (.holdRelease, "Hold & release")],
                    selection: mode
                )
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - ASR model

struct OnboardingAsrStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingNote(
                text: "Download a model, then press \"Use\" to make it active. Parakeet EOU (English) "
                    + "is a fast default; Nemotron Multilingual covers ~40 languages."
            )
            // The Settings ASR list, reused whole - download / delete / "Use" / "Active" all work here.
            ModelManagerView()
        }
    }
}

// MARK: - Microphone & access

struct OnboardingMicrophoneStep: View {
    @Environment(TranscriptionViewModel.self) private var vm

    /// "System Default" (empty UID) followed by the live input devices.
    private var deviceOptions: [(value: String, label: String)] {
        [(value: "", label: "System Default")] + vm.availableInputDevices.map { (value: $0.uid, label: $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingNote(
                text: "Choose which microphone records your speech, then grant the access Mispher needs. "
                    + "Everything runs on-device - these are local macOS permissions, not accounts."
            )
            SettingsCard {
                SettingsRow(
                    title: "Input device",
                    subtitle: "The microphone used for recording. \"System Default\" follows your macOS sound settings."
                ) {
                    GlassDropdown(
                        options: deviceOptions,
                        selection: Binding(get: { vm.selectedInputDeviceUID }, set: { vm.selectedInputDeviceUID = $0 }),
                        maxWidth: 220,
                        displayLabel: vm.selectedInputDeviceLabel
                    )
                }
            }
            SettingsCard {
                OnboardingAccessRow(
                    title: "Microphone",
                    subtitle: "Required to record and transcribe your speech.",
                    granted: vm.micPermissionGranted,
                    grant: { Task { await vm.requestMicrophonePermission() } }
                )
                Hairline().opacity(0.5)
                OnboardingAccessRow(
                    title: "Accessibility",
                    subtitle: "Lets global shortcuts fire when Mispher isn't focused, and lets Rewrite replace selected text.",
                    granted: vm.accessibilityTrusted,
                    grant: { vm.promptAccessibility() },
                    openSettingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                Hairline().opacity(0.5)
                OnboardingNotesAccessRow(vm: vm)
            }
        }
        .onAppear {
            vm.refreshInputDevices()
            vm.refreshMicPermission()
            vm.refreshAccessibilityTrust()
        }
        // Re-read statuses when the user returns from System Settings after granting access.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.refreshMicPermission()
            vm.refreshAccessibilityTrust()
        }
    }
}

/// A permission row for the onboarding "Microphone & access" step: shows a "Granted" check once the
/// access is in place, otherwise a "Grant" button (and, for Accessibility, an "Open Settings" link
/// since macOS won't re-prompt once the app is listed).
private struct OnboardingAccessRow: View {
    let title: String
    let subtitle: String
    let granted: Bool
    var grantLabel = "Grant"
    let grant: () -> Void
    var openSettingsURL: String?

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            if granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Granted")
                }
                .font(.sans(11.5, weight: .medium))
                .foregroundStyle(Palette.accent)
            } else {
                HStack(spacing: 8) {
                    if let openSettingsURL {
                        Button("Open Settings") {
                            if let url = URL(string: openSettingsURL) { NSWorkspace.shared.open(url) }
                        }
                        .buttonStyle(.plain)
                        .font(.sans(11, weight: .medium))
                        .foregroundStyle(Palette.fg2)
                    }
                    Button(grantLabel) { grant() }
                        .buttonStyle(GlassPillButtonStyle())
                }
            }
        }
    }
}

/// The Apple Notes (Automation) row. Unlike Microphone / Accessibility there's no cheap way to read
/// the current Automation status without prompting, so this row tracks its own result: it shows
/// "Grant", then "Granting…" while the (background) check runs and Notes is briefly launched, then
/// flips to "Granted" if access is in place. Optional - it only matters for the Ask agent.
private struct OnboardingNotesAccessRow: View {
    let vm: TranscriptionViewModel
    @State private var granted = false
    @State private var busy = false

    var body: some View {
        OnboardingAccessRow(
            title: "Apple Notes",
            subtitle: "Optional - lets the Ask agent read and update your Apple Notes when you ask it to.",
            granted: granted,
            grantLabel: busy ? "Granting…" : "Grant",
            grant: {
                guard !busy else { return }
                busy = true
                Task {
                    granted = await vm.promptAutomationAccess()
                    busy = false
                }
            }
        )
    }
}

// MARK: - Recording window

struct OnboardingPresentationStep: View {
    @Environment(TranscriptionViewModel.self) private var vm
    @AppStorage("mispher.askPresentationIndependent") private var askStyleOverride = false

    private var presentationOptions: [GlassOptionPicker<RecordingPresentation>.Option] {
        RecordingPresentation.allCases.filter { $0 != .mainWindow }.map {
            .init(value: $0, label: $0.label, detail: $0.detail, systemImage: $0.systemImage)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingNote(
                text: "Choose how overlays appear while recording. Voice modes and Ask can each use a "
                    + "different style - the compact options stay out of the way."
            )
            SettingsCard {
                Text("Voice modes - Transcription, Rewrite, and Translate")
                    .font(.sans(12, weight: .medium))
                    .foregroundStyle(Palette.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GlassOptionPicker(
                    options: presentationOptions,
                    selection: Binding(get: { vm.recordingPresentation }, set: { vm.recordingPresentation = $0 })
                )
                if vm.recordingPresentation == .floating {
                    Hairline().opacity(0.5)
                    SettingToggleRow(
                        title: "Appear near the pointer",
                        subtitle: "Show the floating card next to the mouse pointer each time recording starts.",
                        isOn: Binding(get: { vm.floatingFollowsPointer }, set: { vm.floatingFollowsPointer = $0 })
                    )
                }
            }
            SettingsCard {
                SettingToggleRow(
                    title: "Different style for Ask",
                    subtitle: "Let Ask use a different overlay style than the voice modes.",
                    isOn: $askStyleOverride
                )
                .onChange(of: askStyleOverride) { _, newValue in
                    if newValue {
                        vm.askPresentation = vm.recordingPresentation == .dynamicIsland
                            ? .floatingNotch : .dynamicIsland
                    } else {
                        vm.askPresentation = vm.recordingPresentation
                    }
                }
                if askStyleOverride {
                    Hairline().opacity(0.5)
                    GlassOptionPicker(
                        options: presentationOptions,
                        selection: Binding(get: { vm.askPresentation }, set: { vm.askPresentation = $0 })
                    )
                }
            }
        }
    }
}

// MARK: - Control method (dial vs shortcuts)

/// The fork: launch modes with the radial dial (one gesture, no per-mode shortcuts) or with an
/// individual shortcut per mode (the classic flow - each later feature step then shows its shortcut).
/// The choice is just ``TranscriptionViewModel/radialEnabled``, which the rest of the wizard reads.
struct OnboardingControlStep: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingNote(text: "Pick how you launch Mispher's modes. You can switch this anytime in Settings.")
            SettingsCard {
                GlassOptionPicker<Bool>(
                    options: [
                        .init(
                            value: true, label: "Radial dial",
                            detail: "Hold one key, aim at a mode, and release - one gesture for transcribe, "
                                + "translate, rewrite, and ask.",
                            systemImage: "dial.medium"
                        ),
                        .init(
                            value: false, label: "Individual shortcuts",
                            detail: "A separate key combo per mode, with push-to-talk, trigger, or hold & release.",
                            systemImage: "keyboard"
                        )
                    ],
                    selection: Binding(get: { vm.radialEnabled }, set: { vm.radialEnabled = $0 })
                )
            }
            if vm.radialEnabled { dialSetup } else { shortcutSetup }
        }
    }

    /// Dial branch: the editable wheel + the hold trigger. No per-mode shortcuts needed.
    private var dialSetup: some View {
        SettingsCard {
            HStack {
                Spacer(minLength: 0)
                RadialLayoutWheel(layout: Binding(get: { vm.radialLayout }, set: { vm.radialLayout = $0 }))
                Spacer(minLength: 0)
            }
            Text("Hold the trigger, aim at a slice, and release to start it - or press an arrow key. "
                + "Tap a slice to change what it launches.")
                .font(.sans(11))
                .foregroundStyle(Palette.fg2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Hairline().opacity(0.5)
            SettingsRow(title: "Dial trigger", subtitle: "Hold this to show the dial. Default left ⌥.") {
                KeyRecorderField(hotkey: vm.radialShortcut) { vm.radialShortcut = $0 }
            }
        }
    }

    /// Shortcuts branch: the transcription shortcut here; Rewrite / Translate / Ask follow on their steps.
    private var shortcutSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                OnboardingShortcutRow(
                    title: "Transcription",
                    subtitle: "Records, then drops the text in (and translates it when translation is on).",
                    hotkey: vm.transcriptionShortcut,
                    onChange: { vm.transcriptionShortcut = $0 },
                    mode: Binding(get: { vm.transcriptionMode }, set: { vm.transcriptionMode = $0 })
                )
            }
            OnboardingInfoBox(text: "Rewrite, Translate, and Ask each get their own shortcut on the next steps.")
        }
    }
}

// MARK: - Dictation cleanup

struct OnboardingCleanupStep: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingNote(
                text: "After you stop dictating, Mispher can polish the transcript on-device - punctuation, "
                    + "capitalization, numbers, and filler. Optional."
            )
            // Mirror the Settings ▸ Dictation layout: the master toggle and the cleanup model each get
            // their own card, with the independent deterministic post-processing (filler words) below.
            SettingsCard {
                SettingToggleRow(
                    title: "Enable Dictation",
                    subtitle: "Send the transcript to the model below to fix and clean it up. "
                        + "Transcription itself always works.",
                    isOn: Binding(get: { vm.dictationEnabled }, set: { vm.dictationEnabled = $0 })
                )
            }
            if vm.dictationEnabled {
                SettingsCard {
                    SettingsRow(
                        title: "Cleanup model",
                        subtitle: "The on-device model used for AI cleanup."
                    ) {
                        onboardingModelMenu(current: vm.cleanupModelId, shortName: vm.cleanupModel?.shortName) {
                            vm.cleanupModelId = $0
                        }
                    }
                }
            }
            SettingsCard {
                SettingToggleRow(
                    title: "Remove filler words",
                    subtitle: "Strip \"um\", \"uh\", and similar hesitations from the transcript.",
                    isOn: Binding(get: { vm.removeFillerWords }, set: { vm.removeFillerWords = $0 })
                )
            }
            if vm.dictationEnabled {
                OnboardingInfoBox(
                    text: "You can customize the cleanup prompt - how the model rewrites your transcript - "
                        + "anytime in Settings ▸ Dictation."
                )
            }
        }
    }
}

// MARK: - Rewrite

struct OnboardingRewriteStep: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingNote(
                text: "Highlight text in any app, hold the shortcut, and speak an edit - it replaces the "
                    + "selection in place. Needs Accessibility access (macOS will prompt you). Optional."
            )
            SettingsCard {
                SettingToggleRow(
                    title: "Enable Rewrite",
                    subtitle: "Turn the Rewrite feature on. When off, its shortcut is hidden and won't fire.",
                    isOn: Binding(get: { vm.rewriteEnabled }, set: { vm.rewriteEnabled = $0 })
                )
            }
            if vm.rewriteEnabled {
                SettingsCard {
                    SettingsRow(
                        title: "Rewrite model",
                        subtitle: "The on-device model that rewrites selected text. Download models in Local models."
                    ) {
                        onboardingModelMenu(current: vm.rewriteModelId, shortName: vm.rewriteModel?.shortName) {
                            vm.rewriteModelId = $0
                        }
                    }
                }
                if !vm.radialEnabled {
                    SettingsCard {
                        OnboardingShortcutRow(
                            title: "Rewrite selection",
                            subtitle: "Speak an edit to replace the highlighted text in place.",
                            hotkey: vm.rewriteShortcut,
                            onChange: { vm.rewriteShortcut = $0 },
                            mode: Binding(get: { vm.rewriteMode }, set: { vm.rewriteMode = $0 })
                        )
                    }
                }
                OnboardingInfoBox(
                    text: "You can customize the rewrite prompt anytime in Settings ▸ Rewrite."
                )
            }
        }
    }
}

// MARK: - Translate

struct OnboardingTranslateStep: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingNote(
                text: "When on, your finished speech is translated into the target language before it's "
                    + "inserted. The Translate shortcut also translates a one-off into that language. Optional."
            )
            SettingsCard {
                SettingToggleRow(
                    title: "Enable Translation",
                    subtitle: "Turn translation on. When off, the Translate shortcut is hidden and "
                        + "no translation happens anywhere.",
                    isOn: Binding(get: { vm.translateEnabled }, set: { vm.translateEnabled = $0 })
                )
            }
            if vm.translateEnabled {
                SettingsCard {
                    SettingToggleRow(
                        title: "Always translate transcription",
                        subtitle: "Automatically translate what you dictate into the target language, every time.",
                        isOn: Binding(get: { vm.translationEnabled }, set: { vm.translationEnabled = $0 })
                    )
                    Hairline().opacity(0.5)
                    SettingsRow(title: "Target language", subtitle: "The language to translate into.") {
                        GlassDropdown(
                            options: vm.translationLanguages.map { (value: $0.rawValue, label: $0.displayName) },
                            selection: Binding(
                                get: { vm.translationTargetLanguage.rawValue },
                                set: { vm.translationTargetLanguage = TranslationLanguage(rawValue: $0) ?? .english }
                            ),
                            maxWidth: 200,
                            displayLabel: vm.translationTargetLanguage.displayName
                        )
                    }
                    Hairline().opacity(0.5)
                    SettingsRow(
                        title: "Translation model",
                        subtitle: "The on-device model that translates. Download models in Local models."
                    ) {
                        onboardingModelMenu(current: vm.translationModelId, shortName: vm.translationModel?.shortName) {
                            vm.translationModelId = $0
                        }
                    }
                }
                if !vm.radialEnabled {
                    SettingsCard {
                        OnboardingShortcutRow(
                            title: "Translate",
                            subtitle: "Records, translates into the target language, and inserts it into the focused field.",
                            hotkey: vm.translateShortcut,
                            onChange: { vm.translateShortcut = $0 },
                            mode: Binding(get: { vm.translateMode }, set: { vm.translateMode = $0 })
                        )
                    }
                }
                OnboardingInfoBox(
                    text: "You can customize the translation prompt anytime in Settings ▸ Translate."
                )
            }
        }
    }
}

// MARK: - Ask

struct OnboardingAskStep: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingNote(
                text: "Hold the Ask shortcut and speak a question; the on-device DeepAgent plans, uses "
                    + "tools, and streams the answer back. Turn it off to hide its shortcuts entirely. "
                    + "Optional."
            )
            SettingsCard {
                SettingToggleRow(
                    title: "Enable Ask",
                    subtitle: "Turn the Ask feature on. When off, its shortcuts are hidden and won't fire.",
                    isOn: Binding(get: { vm.askEnabled }, set: { vm.askEnabled = $0 })
                )
            }
            if vm.askEnabled {
                DeepAgentModelPickers()
                if !vm.radialEnabled {
                    SettingsCard {
                        OnboardingShortcutRow(
                            title: "Ask - new conversation",
                            subtitle: "Records, then answers with the DeepAgent, starting a fresh conversation.",
                            hotkey: vm.askShortcut,
                            onChange: { vm.askShortcut = $0 },
                            mode: Binding(get: { vm.askMode }, set: { vm.askMode = $0 })
                        )
                        Hairline().opacity(0.5)
                        OnboardingShortcutRow(
                            title: "Ask - continue",
                            subtitle: "Records, then continues your last conversation instead of starting over.",
                            hotkey: vm.askContinueShortcut,
                            onChange: { vm.askContinueShortcut = $0 },
                            mode: Binding(get: { vm.askContinueMode }, set: { vm.askContinueMode = $0 })
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Power features (MCP / middleware pointers)

struct OnboardingPowerStep: View {
    @Environment(TranscriptionViewModel.self) private var vm
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingNote(
                text: "Go further whenever you like. Personalize your shortcuts and timing, and - for the "
                    + "agent - connect MCP tools and tune middleware. These all live in Settings; open one "
                    + "now or come back later."
            )
            SettingsCard {
                powerRow(
                    icon: "keyboard",
                    title: "Shortcuts & timing",
                    detail: "Rebind every shortcut and fine-tune the activation: push-to-talk delay, "
                        + "auto-end on silence, hold & release, and more.",
                    tab: .shortcuts
                )
                Hairline().opacity(0.5)
                powerRow(
                    icon: "powerplug",
                    title: "MCP servers",
                    detail: "Connect external tools - filesystem, web, or your own servers.",
                    tab: .mcp
                )
                Hairline().opacity(0.5)
                powerRow(
                    icon: "puzzlepiece.extension",
                    title: "Middleware",
                    detail: "Choose which built-in tools the agent can use, and how they're approved.",
                    tab: .middleware
                )
            }
        }
    }

    private func powerRow(icon: String, title: String, detail: String, tab: SettingsTab) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.sans(12.5, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text(detail)
                    .font(.sans(11))
                    .foregroundStyle(Palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open") { open(tab) }
                .buttonStyle(GlassPillButtonStyle())
        }
    }

    /// Deep-link Settings to a pane: stash the target on the view model (Settings reads + clears it)
    /// and open the Settings window.
    private func open(_ tab: SettingsTab) {
        vm.pendingSettingsTab = tab
        openWindow(id: MispherApp.settingsWindowID)
    }
}

// MARK: - Finish

struct OnboardingFinishStep: View {
    @Environment(TranscriptionViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingNote(text: readyText)
            SettingsCard {
                if vm.radialEnabled {
                    summaryRow("dial.medium", "Control", "Radial dial", vm.radialShortcut.display)
                    Hairline().opacity(0.5)
                }
                summaryRow("waveform", "Transcription", vm.selectedModel.displayName, featureShortcut(vm.transcriptionShortcut))
                if vm.dictationEnabled {
                    Hairline().opacity(0.5)
                    summaryRow("wand.and.stars", "Dictation", vm.cleanupModel?.shortName ?? "Default", nil)
                }
                Hairline().opacity(0.5)
                summaryRow("rectangle.on.rectangle", "Recording window",
                           vm.askPresentation != vm.recordingPresentation
                               ? "\(vm.recordingPresentation.label) - Ask: \(vm.askPresentation.label)"
                               : vm.recordingPresentation.label,
                           nil)
                Hairline().opacity(0.5)
                summaryRow(
                    "pencil.line", "Rewrite",
                    vm.rewriteEnabled ? (vm.rewriteModel?.shortName ?? "Default") : "Off",
                    vm.rewriteEnabled ? featureShortcut(vm.rewriteShortcut) : nil
                )
                Hairline().opacity(0.5)
                summaryRow(
                    "translate", "Translate",
                    vm.translateEnabled ? (vm.translationModel?.shortName ?? "Default") : "Off",
                    vm.translateEnabled ? featureShortcut(vm.translateShortcut) : nil
                )
                Hairline().opacity(0.5)
                summaryRow(
                    "sparkles", "Ask", askSummary,
                    vm.askEnabled ? featureShortcut(vm.askShortcut) : nil
                )
            }
        }
    }

    /// The closing line, adapted to the chosen control method.
    private var readyText: String {
        let lead = vm.radialEnabled
            ? "You're ready to go - hold \(vm.radialShortcut.display) anywhere, aim at a mode, and release to start it."
            : "You're ready to go - press your transcription shortcut anywhere to start dictating."
        return lead + " Pre-download more models in Settings under ASR Models and Local models, and re-run "
            + "this setup any time from the menu bar's \"Run setup again\"."
    }

    /// A per-feature shortcut chip is only meaningful when the dial is off (otherwise the chords don't
    /// fire); with the dial on, the single dial trigger is shown in the Control row instead.
    private func featureShortcut(_ hotkey: Hotkey) -> String? {
        vm.radialEnabled ? nil : hotkey.display
    }

    /// The Ask recap value: the DeepAgent's planner model, plus the vision model when one is set
    /// ("planner + vision"), or just the planner when vision is None. "Off" when Ask is disabled.
    private var askSummary: String {
        guard vm.askEnabled else { return "Off" }
        if let vision = vm.askVisionShortName { return "\(vm.askPlannerShortName) + \(vision)" }
        return vm.askPlannerShortName
    }

    private func summaryRow(_ icon: String, _ title: String, _ value: String, _ shortcut: String?) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 20)
            Text(title)
                .font(.sans(12.5, weight: .medium))
                .foregroundStyle(Palette.fg)
            Spacer(minLength: 8)
            Text(value)
                .font(.sans(11.5))
                .foregroundStyle(Palette.fg1)
                .lineLimit(1)
            if let shortcut {
                Text(shortcut)
                    .font(.mono(10.5))
                    .foregroundStyle(Palette.fg2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.06)))
            }
        }
    }
}
