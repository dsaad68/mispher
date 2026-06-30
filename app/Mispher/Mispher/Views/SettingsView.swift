import AppKit
import DeepAgents
import DeepAgentsMLX
import SwiftUI

/// Settings presented as a vertically-tabbed dialog: a glass sidebar of sections
/// on the left (General · Shortcuts · ASR Models · Local models) and the selected
/// section's content on the right. Matches the HUD's dark glassmorphic language.
/// Translation is controlled from the HUD header, so it has no Settings tab.
struct SettingsView: View {
    @Environment(TranscriptionViewModel.self) private var vm
    @State private var tab: SettingsTab = .general
    @AppStorage("mispher.askPresentationIndependent") private var askStyleOverride = false
    @FocusState private var focusedDictField: DictFieldFocus?
    /// Drives the rewrite prompt editor's "Insert" button (which pill to drop, and when).
    @State private var cleanupInsert = PromptPillInsert()
    @State private var rewriteInsert = PromptPillInsert()
    /// Same, for the translate prompt editor (target-language and input-text pills).
    @State private var translateInsert = PromptPillInsert()

    /// Identifies one custom-dictionary text field so SwiftUI can track which one is focused.
    private enum DictFieldFocus: Hashable { case trigger(UUID), replacement(UUID) }

    var body: some View {
        VStack(spacing: 0) {
            // Reserve a titlebar band so the window's traffic lights clear the sidebar
            // header (this is a hidden-titlebar window, so the lights overlay the content).
            Color.clear.frame(height: 28)
            HStack(alignment: .top, spacing: 0) {
                sidebar
                Rectangle().fill(Palette.border).frame(width: 1)
                content
            }
        }
        // Fixed-size window: the sidebar and the tab title stay pinned, and only the tab content
        // scrolls when it's taller than the area below the title. The root fills the whole window so
        // the frosted background covers every pixel (no grey strip), and the window no longer
        // resizes from tab to tab.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                VisualEffectView(material: .hudWindow)
                Palette.glassFill.opacity(0.5)
            }
            .ignoresSafeArea()
        }
        .background(SettingsWindowConfigurator(
            lockedContentSize: CGSize(width: Self.windowWidth, height: Self.windowHeight)
        ))
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onAppear {
            Task { await vm.refreshDownloadStates() }
            vm.refreshInputDevices()
            applyPendingTab()
        }
        // Honor a deep-link from onboarding's "power features" step whether the window was just
        // opened (onAppear) or is already open when the request lands (onChange).
        .onChange(of: vm.pendingSettingsTab) { _, _ in applyPendingTab() }
    }

    /// Jump to the pane the onboarding wizard asked for, then clear the request so a later manual
    /// tab switch isn't snapped back.
    private func applyPendingTab() {
        guard let pending = vm.pendingSettingsTab else { return }
        tab = pending
        vm.pendingSettingsTab = nil
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                BrandMarkView(size: 16)
                Text("Settings")
                    .font(.title(22, weight: .semibold))
                    .foregroundStyle(Palette.fg)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 14)

            ForEach(SettingsTab.allCases) { item in
                SidebarTab(tab: item, isSelected: tab == item) {
                    tab = item
                }
            }
        }
        .padding(12)
        .frame(width: 184, alignment: .top)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(tab.title)
                    .font(.title(21, weight: .semibold))
                    .foregroundStyle(Palette.fg)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Rectangle().fill(Palette.border).frame(height: 1)

            // The content scrolls within the fixed window; it fills the area below the static title
            // and only actually scrolls when the tab is taller than that area.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .general: generalTab
                    case .dictation: dictationTab
                    case .rewrite: rewriteTab
                    case .translate: translateTab
                    case .ask: askTab
                    case .shortcuts: shortcutsTab
                    case .models: ModelManagerView()
                    case .localModels: LocalModelsView()
                    case .middleware: MiddlewareView()
                    case .mcp: MCPServersView()
                    case .advanced: advancedTab
                    case .about: aboutTab
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The fixed window size. The sidebar + title are static; long tabs scroll their content.
    static let windowWidth: CGFloat = 760
    static var windowHeight: CGFloat {
        min(740, max(440, (NSScreen.main?.visibleFrame.height ?? 740) - 40))
    }

    // MARK: General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Behavior")
                SettingsCard {
                    SettingToggleRow(
                        title: "Auto-copy when finished",
                        subtitle: "Copy the transcript to the clipboard the moment recording stops.",
                        isOn: Binding(get: { vm.autoCopyOnFinish }, set: { vm.autoCopyOnFinish = $0 })
                    )
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Microphone")
                SettingsCard {
                    SettingsRow(
                        title: "Input device",
                        subtitle: "The microphone used for recording. \"System Default\" follows your macOS sound settings."
                    ) {
                        GlassDropdown(
                            options: microphoneOptions,
                            selection: Binding(get: { vm.selectedInputDeviceUID }, set: { vm.selectedInputDeviceUID = $0 }),
                            maxWidth: 220,
                            displayLabel: vm.selectedInputDeviceLabel
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Recording window")
                SettingsCard {
                    Text("Voice modes - Transcription, Rewrite, and Translate")
                        .font(.sans(12, weight: .medium))
                        .foregroundStyle(Palette.fg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GlassOptionPicker(
                        options: recordingWindowOptions,
                        selection: Binding(get: { vm.recordingPresentation }, set: { vm.recordingPresentation = $0 })
                    )
                    if vm.recordingPresentation == .floating {
                        Hairline().opacity(0.5)
                        SettingToggleRow(
                            title: "Appear near the pointer",
                            subtitle: "Show the floating card next to the mouse pointer each time recording "
                                + "starts, instead of where you last left it.",
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
                            options: recordingWindowOptions,
                            selection: Binding(get: { vm.askPresentation }, set: { vm.askPresentation = $0 })
                        )
                    }
                }
            }
        }
    }

    /// Options for the "Recording window" pickers, built from ``RecordingPresentation``. The
    /// main-window style is not offered (compact overlays only).
    private var recordingWindowOptions: [GlassOptionPicker<RecordingPresentation>.Option] {
        RecordingPresentation.allCases.filter { $0 != .mainWindow }.map {
            .init(value: $0, label: $0.label, detail: $0.detail, systemImage: $0.systemImage)
        }
    }

    /// Options for the microphone picker: "System Default" (empty UID) followed by the live devices.
    private var microphoneOptions: [(value: String, label: String)] {
        [(value: "", label: "System Default")] + vm.availableInputDevices.map { (value: $0.uid, label: $0.name) }
    }

    // MARK: Dictation

    private var dictationTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Dictation")
                SettingsCard {
                    SettingToggleRow(
                        title: "Enable Dictation",
                        subtitle: "After recording, send the transcript to an on-device model to fix and clean it up "
                            + "- punctuation, capitalization, numbers, and filler. Transcription itself always works.",
                        isOn: Binding(get: { vm.dictationEnabled }, set: { vm.dictationEnabled = $0 })
                    )
                }
            }

            if vm.dictationEnabled {
                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "Model")
                    SettingsCard {
                        SettingsRow(
                            title: "Cleanup model",
                            subtitle: "The on-device language model used for AI dictation cleanup. "
                                + "Download models in Local models."
                        ) {
                            modelMenu(current: vm.cleanupModelId, shortName: vm.cleanupModel?.shortName) { vm.cleanupModelId = $0 }
                        }
                    }
                }
            }

            if vm.dictationEnabled {
                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "Prompt")
                    SettingsCard {
                        Text("Instructions the cleanup model follows. Drop the “Transcript” pill where your "
                            + "dictation should appear; it's cleaned, never answered - a dictated question "
                            + "stays a question.")
                            .font(.sans(11))
                            .foregroundStyle(Palette.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        promptPillEditor(
                            text: Binding(get: { vm.cleanupPrompt }, set: { vm.cleanupPrompt = $0 }),
                            tokens: [PromptToken(token: CleanupPrompt.inputToken, label: "Transcript")],
                            insert: $cleanupInsert
                        )
                        HStack(spacing: 10) {
                            insertPillButton(
                                "Insert transcript", token: CleanupPrompt.inputToken, into: $cleanupInsert,
                                present: vm.cleanupPrompt.contains(CleanupPrompt.inputToken)
                            )
                            Spacer(minLength: 0)
                            Button("Reset to default") { vm.cleanupPrompt = CleanupPrompt.defaultInstructions }
                                .buttonStyle(GlassPillButtonStyle())
                                .disabled(vm.cleanupPrompt == CleanupPrompt.defaultInstructions)
                        }
                    }
                }
            }

            // Deterministic post-processing, applied to every transcript independently of AI cleanup
            // (and to Ask transcripts), so it stays available even when Dictation is off.
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Transcript post-processing")
                SettingsCard {
                    SettingToggleRow(
                        title: "Remove filler words",
                        subtitle: "Strip “um”, “uh”, and similar hesitations from the transcript.",
                        isOn: Binding(get: { vm.removeFillerWords }, set: { vm.removeFillerWords = $0 })
                    )
                }
            }

            dictionarySection
        }
    }

    // MARK: Rewrite

    private var rewriteTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Rewrite")
                SettingsCard {
                    SettingToggleRow(
                        title: "Enable Rewrite",
                        subtitle: "Rewrite selected text by voice. When off, the Rewrite shortcut is hidden and won't fire.",
                        isOn: Binding(get: { vm.rewriteEnabled }, set: { vm.rewriteEnabled = $0 })
                    )
                }
            }
            if vm.rewriteEnabled {
                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "Model")
                    SettingsCard {
                        SettingsRow(
                            title: "Voice rewrite model",
                            subtitle: "The on-device language model used to rewrite selected text by voice. "
                                + "Download models in Local models."
                        ) {
                            modelMenu(current: vm.rewriteModelId, shortName: vm.rewriteModel?.shortName) { vm.rewriteModelId = $0 }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "Prompt")
                    SettingsCard {
                        Text("Instructions the rewrite model follows when you edit a selection by voice. "
                            + "Drop the “Selected text” pill where the highlighted text should appear; your "
                            + "spoken words are the request.")
                            .font(.sans(11))
                            .foregroundStyle(Palette.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        promptPillEditor(
                            text: Binding(get: { vm.rewritePrompt }, set: { vm.rewritePrompt = $0 }),
                            tokens: [PromptToken(token: RewritePrompt.selectionToken, label: "Selected text")],
                            insert: $rewriteInsert
                        )
                        HStack(spacing: 10) {
                            insertPillButton(
                                "Insert selected text", token: RewritePrompt.selectionToken, into: $rewriteInsert,
                                present: vm.rewritePrompt.contains(RewritePrompt.selectionToken)
                            )
                            Spacer(minLength: 0)
                            Button("Reset to default") { vm.rewritePrompt = RewritePrompt.defaultInstructions }
                                .buttonStyle(GlassPillButtonStyle())
                                .disabled(vm.rewritePrompt == RewritePrompt.defaultInstructions)
                        }
                    }
                }
            }
        }
    }

    /// Shared chrome for the rewrite/translate pill editors.
    private func promptPillEditor(
        text: Binding<String>, tokens: [PromptToken], insert: Binding<PromptPillInsert>
    ) -> some View {
        PromptPillField(
            text: text,
            tokens: tokens,
            insert: insert.wrappedValue
        )
        .frame(minHeight: 210, maxHeight: 360)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    /// An "Insert <pill>" button, disabled (and quietened) once that placeholder is already present
    /// so the prompt keeps a single instance of each.
    private func insertPillButton(
        _ title: String, token: String, into insert: Binding<PromptPillInsert>, present: Bool
    ) -> some View {
        Button {
            insert.wrappedValue = PromptPillInsert(counter: insert.wrappedValue.counter + 1, token: token)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle")
                Text(title)
                    .font(.sans(11.5, weight: .medium))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(present ? Palette.fg3 : Palette.accent)
        }
        .buttonStyle(.plain)
        .disabled(present)
        .help(present ? "The prompt already has this placeholder." : "Drop the placeholder at the cursor.")
    }

    // MARK: Translate

    private var translateTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Translation")
                SettingsCard {
                    SettingToggleRow(
                        title: "Enable Translation",
                        subtitle: "Translate your speech on-device. When off, the Translate shortcut is hidden and "
                            + "no translation happens anywhere.",
                        isOn: Binding(get: { vm.translateEnabled }, set: { vm.translateEnabled = $0 })
                    )
                    if vm.translateEnabled {
                        Hairline().opacity(0.5)
                        SettingToggleRow(
                            title: "Always translate transcription",
                            subtitle: "Automatically translate what you dictate into the target language, every time.",
                            isOn: Binding(get: { vm.translationEnabled }, set: { vm.translationEnabled = $0 })
                        )
                    }
                }
            }

            if vm.translateEnabled {
                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "Model")
                    SettingsCard {
                        SettingsRow(
                            title: "Translation model",
                            subtitle: "The on-device language model that translates the transcript. "
                                + "Download models in Local models."
                        ) {
                            modelMenu(current: vm.translationModelId, shortName: vm.translationModel?.shortName) {
                                vm.translationModelId = $0
                            }
                        }
                        Hairline().opacity(0.5)
                        SettingsRow(
                            title: "Target language",
                            subtitle: "The language the \(vm.translateShortcut.display) shortcut translates into."
                        ) {
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
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "Prompt")
                    SettingsCard {
                        Text("Instructions the translation model follows. Drop the “Target language” pill "
                            + "where the chosen language should be named, and the “Input text” pill where the "
                            + "transcript goes; both are filled in when you translate.")
                            .font(.sans(11))
                            .foregroundStyle(Palette.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        promptPillEditor(
                            text: Binding(get: { vm.translationPrompt }, set: { vm.translationPrompt = $0 }),
                            tokens: [
                                PromptToken(token: TranslationPrompt.languageToken, label: "Target language"),
                                PromptToken(token: TranslationPrompt.inputToken, label: "Input text")
                            ],
                            insert: $translateInsert
                        )
                        HStack(spacing: 14) {
                            insertPillButton(
                                "Insert target language", token: TranslationPrompt.languageToken, into: $translateInsert,
                                present: vm.translationPrompt.contains(TranslationPrompt.languageToken)
                            )
                            insertPillButton(
                                "Insert input text", token: TranslationPrompt.inputToken, into: $translateInsert,
                                present: vm.translationPrompt.contains(TranslationPrompt.inputToken)
                            )
                            Spacer(minLength: 0)
                            Button("Reset to default") { vm.translationPrompt = TranslationPrompt.defaultInstructions }
                                .buttonStyle(GlassPillButtonStyle())
                                .disabled(vm.translationPrompt == TranslationPrompt.defaultInstructions)
                        }
                    }
                }
            }
        }
    }

    // MARK: Advanced

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Developer")
                SettingsCard {
                    SettingToggleRow(
                        title: "Log agent messages",
                        subtitle: "Append every agent message - human, assistant, and tool, in order - "
                            + "to a timestamped JSONL file (YYYY-MM-DD-HH-MM-SS), for later analysis.",
                        isOn: Binding(get: { vm.logAgentMessages }, set: { vm.logAgentMessages = $0 })
                    )
                    if vm.logAgentMessages {
                        Hairline().opacity(0.5)
                        SettingsRow(title: "Log folder", subtitle: agentLogPath) {
                            HStack(spacing: 8) {
                                Button("Choose…") { chooseLogFolder() }
                                    .buttonStyle(GlassPillButtonStyle())
                                if !vm.agentLogDirectory.isEmpty {
                                    Button("Default") { vm.agentLogDirectory = "" }
                                        .buttonStyle(GlassPillButtonStyle())
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Glass dropdown for choosing an on-device language model (shared by the cleanup and
    /// rewrite model rows). Reuses the app-wide `GlassDropdown` so it matches the header
    /// model picker; the pill shows the compact short name while the menu lists full rows.
    private func modelMenu(current: String, shortName: String?, select: @escaping (String) -> Void) -> some View {
        VStack(alignment: .center, spacing: 5) {
            GlassDropdown(
                options: MlxModel.languageCatalog.map { (value: $0.id, label: "\($0.displayName) · \($0.detail)") },
                selection: Binding(get: { current }, set: { select($0) }),
                maxWidth: 220,
                displayLabel: shortName ?? "Select…"
            )
            ModelMemoryHint(modelId: current)
        }
    }

    /// Editor for the custom find→replace dictionary (T2): comma-separated triggers → a
    /// replacement, one rule per row, with add/remove.
    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Custom dictionary")
            SettingsCard {
                if vm.customDictionary.isEmpty {
                    Text("Fix recurring mishears or force a spelling - e.g. “k8s, kates” → “Kubernetes”. "
                        + "Matching is whole-word and case-insensitive, applied to the finished transcript.")
                        .font(.sans(11))
                        .foregroundStyle(Palette.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(vm.customDictionary) { entry in
                        dictionaryRow(id: entry.id)
                        if entry.id != vm.customDictionary.last?.id {
                            Hairline().opacity(0.5)
                        }
                    }
                }
                Hairline().opacity(0.5)
                Button {
                    vm.customDictionary.append(CustomDictionaryEntry())
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text("Add rule")
                            .font(.sans(11.5, weight: .medium))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One editable dictionary rule: triggers field → replacement field, plus a delete button.
    /// Resolves the entry by its stable `id` on every access, so deleting a row above can't
    /// shift indices and apply an edit/delete to the wrong entry.
    private func dictionaryRow(id: UUID) -> some View {
        HStack(spacing: 8) {
            dictionaryField(placeholder: "Triggers (comma-separated)", focus: .trigger(id), text: Binding(
                get: {
                    guard let i = vm.customDictionary.firstIndex(where: { $0.id == id }) else { return "" }
                    return vm.customDictionary[i].triggers.joined(separator: ", ")
                },
                set: { newValue in
                    guard let i = vm.customDictionary.firstIndex(where: { $0.id == id }) else { return }
                    vm.customDictionary[i].triggers = newValue
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            ))
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.fg3)
            dictionaryField(placeholder: "Replacement", focus: .replacement(id), text: Binding(
                get: {
                    guard let i = vm.customDictionary.firstIndex(where: { $0.id == id }) else { return "" }
                    return vm.customDictionary[i].replacement
                },
                set: { newValue in
                    guard let i = vm.customDictionary.firstIndex(where: { $0.id == id }) else { return }
                    vm.customDictionary[i].replacement = newValue
                }
            ))
            Button {
                vm.customDictionary.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.fg3)
            }
            .buttonStyle(.plain)
        }
    }

    private func dictionaryField(placeholder: String, focus: DictFieldFocus, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.sans(11.5))
            .foregroundStyle(Palette.fg)
            .focused($focusedDictField, equals: focus)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    /// The folder the message log writes to (the chosen path, or the default location).
    private var agentLogPath: String {
        vm.agentLogDirectory.isEmpty
            ? "Default - \(AgentLogSettings.defaultDirectory.path)"
            : vm.agentLogDirectory
    }

    /// Pick the directory for agent message logs.
    private func chooseLogFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for agent message logs"
        if panel.runModal() == .OK, let url = panel.url {
            vm.agentLogDirectory = url.path
        }
    }

    // MARK: Shortcuts

    private var shortcutsTab: some View {
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: 14) {
            if !vm.accessibilityTrusted { accessibilityBanner }

            radialPickerSection

            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Global shortcuts")
                SettingsCard {
                    // The per-mode chords are replaced by the radial picker, so they only show when it
                    // is off. Each optional feature's row appears only when its master toggle (on the
                    // feature's own tab) is on, and carries a trailing hairline. Stop is always shown.
                    if !vm.radialEnabled {
                        shortcutRow(
                            title: "Transcription",
                            subtitle: "Records, then drops the text in (and translates it when translation is on)."
                        ) {
                            HStack(spacing: 8) {
                                KeyRecorderField(hotkey: vm.transcriptionShortcut) { vm.transcriptionShortcut = $0 }
                                modeToggle($vm.transcriptionMode)
                            }
                        }
                        Hairline().opacity(0.5)
                        if vm.askEnabled {
                            shortcutRow(
                                title: "Ask",
                                subtitle: "Records, then answers with the Ask model from the Ask tab or toolbar."
                            ) {
                                VStack(alignment: .leading, spacing: 10) {
                                    shortcutSubRow("New conversation", detail: "Starts a fresh conversation each time.") {
                                        HStack(spacing: 8) {
                                            KeyRecorderField(hotkey: vm.askShortcut) { vm.askShortcut = $0 }
                                            modeToggle($vm.askMode)
                                        }
                                    }
                                    shortcutSubRow("Continue", detail: "Continues the last conversation.") {
                                        HStack(spacing: 8) {
                                            KeyRecorderField(hotkey: vm.askContinueShortcut) { vm.askContinueShortcut = $0 }
                                            modeToggle($vm.askContinueMode)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            Hairline().opacity(0.5)
                        }
                        if vm.rewriteEnabled {
                            shortcutRow(
                                title: "Rewrite selection",
                                subtitle: "Highlight text in any app, then speak an edit - it replaces the selection in place. "
                                    + "Needs Accessibility access."
                            ) {
                                HStack(spacing: 8) {
                                    KeyRecorderField(hotkey: vm.rewriteShortcut) { vm.rewriteShortcut = $0 }
                                    modeToggle($vm.rewriteMode)
                                }
                            }
                            Hairline().opacity(0.5)
                        }
                        if vm.translateEnabled {
                            shortcutRow(
                                title: "Translate",
                                subtitle: "Records, translates into the Translate tab's target language, and inserts it "
                                    + "into the focused field."
                            ) {
                                HStack(spacing: 8) {
                                    KeyRecorderField(hotkey: vm.translateShortcut) { vm.translateShortcut = $0 }
                                    modeToggle($vm.translateMode)
                                }
                            }
                            Hairline().opacity(0.5)
                        }
                    } // end if !vm.radialEnabled
                    shortcutRow(
                        title: "Stop",
                        subtitle: "Finalizes the current recording (and commits a paused transcription)."
                    ) {
                        KeyRecorderField(hotkey: vm.stopShortcut, allowsModifierOnly: false) { vm.stopShortcut = $0 }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Timing & behavior")
                SettingsCard {
                    SettingsRow(
                        title: "Push-to-talk start delay",
                        subtitle: "How long to hold before recording begins."
                    ) {
                        GlassSegmented(
                            options: [(0, "Instant"), (1, "1s"), (2, "2s"), (3, "3s")],
                            selection: Binding(get: { vm.pushToTalkStartDelay }, set: { vm.pushToTalkStartDelay = $0 })
                        )
                    }
                    Hairline().opacity(0.5)
                    SettingsRow(
                        title: "Hold & release press length",
                        subtitle: "How long to long-press before it toggles recording."
                    ) {
                        GlassSegmented(
                            options: [(0.3, "0.3s"), (0.5, "0.5s"), (0.8, "0.8s"), (1.2, "1.2s"), (2, "2s"), (3, "3s")],
                            selection: Binding(get: { vm.holdReleaseDuration }, set: { vm.holdReleaseDuration = $0 })
                        )
                    }
                    Hairline().opacity(0.5)
                    SettingToggleRow(
                        title: "Auto-end on silence",
                        subtitle: "Finish a Trigger recording after a pause in speech. Hold & release always auto-ends.",
                        isOn: Binding(get: { vm.silenceAutoEndEnabled }, set: { vm.silenceAutoEndEnabled = $0 })
                    )
                    if vm.silenceAutoEndEnabled || vm.usesHoldRelease {
                        SettingsRow(
                            title: "Silence length",
                            subtitle: "How long the input stays quiet before finishing."
                        ) {
                            GlassSegmented(
                                options: [(1, "1s"), (1.6, "1.6s"), (2.5, "2.5s"), (4, "4s")],
                                selection: Binding(get: { vm.silenceTimeout }, set: { vm.silenceTimeout = $0 })
                            )
                        }
                    }
                    Hairline().opacity(0.5)
                    SettingsRow(
                        title: "When transcription finishes",
                        subtitle: "Pause holds the text until you press Stop; Stop drops it in right away."
                    ) {
                        GlassSegmented(
                            options: [(TranscriptionFinishBehavior.pause, "Pause"), (.stop, "Stop")],
                            selection: Binding(get: { vm.transcriptionFinishBehavior }, set: { vm.transcriptionFinishBehavior = $0 })
                        )
                    }
                }
            }

            Text(shortcutsFooter)
                .font(.sans(11))
                .foregroundStyle(Palette.fg3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            HStack {
                Spacer(minLength: 0)
                Button("Reset shortcuts to defaults") { vm.resetShortcuts() }
                    .buttonStyle(GlassPillButtonStyle())
                    .disabled(vm.shortcutsAreDefault)
            }
        }
        .task {
            // Poll while the tab is open so the banner clears once access is granted.
            while !Task.isCancelled {
                vm.refreshAccessibilityTrust()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func modeToggle(_ selection: Binding<ActivationMode>) -> some View {
        GlassSegmented(
            options: [(ActivationMode.hold, "Push to talk"), (.trigger, "Trigger"), (.holdRelease, "Hold & release")],
            selection: selection
        )
    }

    /// A global-shortcut row laid out vertically: title, a full-width description, then the recorder
    /// + mode controls on their own line below -- so the description gets the whole card width
    /// instead of being squeezed into a narrow column beside the wide controls.
    private func shortcutRow(
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sans(12.5, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text(subtitle)
                    .font(.sans(11))
                    .foregroundStyle(Palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                control()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A labeled sub-row inside a combined shortcut card (e.g. Ask's "New conversation" / "Continue"),
    /// laid out vertically like ``shortcutRow``: label, a full-width detail, then the recorder + mode
    /// controls on their own right-aligned line below -- so the detail gets the whole width instead
    /// of being squeezed into a narrow column beside the wide controls.
    private func shortcutSubRow(
        _ label: String, detail: String, @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.sans(11.5, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text(detail)
                    .font(.sans(10.5))
                    .foregroundStyle(Palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                control()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Prompt shown until the app is trusted for Accessibility (needed for global shortcuts
    /// to work when Mispher isn't focused).
    private var accessibilityBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.warm)
            VStack(alignment: .leading, spacing: 6) {
                Text("Grant Accessibility access so global shortcuts work when Mispher isn't focused.")
                    .font(.sans(11.5))
                    .foregroundStyle(Palette.fg)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Grant Access") { vm.promptAccessibility() }
                        .buttonStyle(.plain)
                        .font(.sans(11, weight: .medium))
                        .foregroundStyle(Palette.warm)
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.sans(11, weight: .medium))
                    .foregroundStyle(Palette.fg2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.warm.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.warm.opacity(0.3), lineWidth: 0.75))
    }
}

// MARK: - About tab

/// The About pane: app + framework versions, doc links, and authorship. In an extension so the main
/// ``SettingsView`` body stays within the type-body length limit.
extension SettingsView {
    var aboutTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Version")
                SettingsCard {
                    SettingsRow(title: "Mispher", subtitle: "The version of the app you're running.") {
                        Text(Self.appVersion)
                            .font(.sans(12, weight: .medium))
                            .foregroundStyle(Palette.fg1)
                    }
                    Hairline().opacity(0.5)
                    SettingsRow(
                        title: "DeepAgents-swift",
                        subtitle: "The on-device agent framework Mispher is built on."
                    ) {
                        Text(DeepAgentsVersion.current)
                            .font(.sans(12, weight: .medium))
                            .foregroundStyle(Palette.fg1)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Documentation")
                SettingsCard {
                    aboutLinkRow(
                        title: "DeepAgents-swift docs",
                        subtitle: "deepagents-swift.verybad.engineer",
                        url: "https://deepagents-swift.verybad.engineer"
                    )
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Made by")
                SettingsCard {
                    aboutLinkRow(
                        title: "Daniel Saad",
                        subtitle: "verybad.engineer",
                        url: "https://verybad.engineer"
                    )
                }
            }
        }
    }

    /// A settings row whose trailing control is a glass pill that opens `url` in the browser.
    private func aboutLinkRow(title: String, subtitle: String, url: String) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Button("Open") {
                if let link = URL(string: url) { NSWorkspace.shared.open(link) }
            }
            .buttonStyle(GlassPillButtonStyle())
        }
    }

    /// The app's marketing version, with the build number appended when it differs (read from the
    /// auto-generated Info.plist: `MARKETING_VERSION` -> `CFBundleShortVersionString`).
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        if let build = info?["CFBundleVersion"] as? String, build != short { return "\(short) (\(build))" }
        return short
    }
}

// MARK: - Ask tab

/// The Ask pane: the master enable switch plus the Ask model picker. In an extension so the main
/// ``SettingsView`` body stays within the type-body length limit.
extension SettingsView {
    var askTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Ask")
                SettingsCard {
                    SettingToggleRow(
                        title: "Enable Ask",
                        subtitle: "Ask a question by voice and get an answer from the on-device DeepAgent. "
                            + "When off, the Ask shortcuts are hidden and won't fire.",
                        isOn: Binding(get: { vm.askEnabled }, set: { vm.askEnabled = $0 })
                    )
                }
            }

            // The DeepAgent's planner / vision models and per-model idle timeouts (see AskSettingsView).
            if vm.askEnabled {
                AskSettingsView()
            }
        }
    }
}

// MARK: - Tabs

/// The Settings panes, in sidebar order. Internal (not private) so the onboarding "power
/// features" step can deep-link to a pane via ``TranscriptionViewModel/pendingSettingsTab``.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, dictation, rewrite, translate, ask, shortcuts, models, localModels, middleware, mcp,
         advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .rewrite: return "Rewrite"
        case .translate: return "Translate"
        case .ask: return "Ask"
        case .shortcuts: return "Shortcuts"
        case .models: return "ASR Models"
        case .localModels: return "Local models"
        case .middleware: return "Middleware"
        case .mcp: return "MCP Servers"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .dictation: return "wand.and.stars"
        case .rewrite: return "pencil.line"
        case .translate: return "translate"
        case .ask: return "sparkles"
        case .shortcuts: return "keyboard"
        case .models: return "cpu"
        case .localModels: return "memorychip"
        case .middleware: return "puzzlepiece.extension"
        case .mcp: return "powerplug"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

private struct SidebarTab: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(tab.title)
                    .font(.sans(12.5, weight: isSelected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Palette.accent : (hovering ? Palette.fg1 : Palette.fg2))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Palette.accentSoft : (hovering ? Color.white.opacity(0.04) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Palette.accentGlow : .clear, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Radial mode picker UI for the Shortcuts tab, split into a same-file extension so the main
/// `SettingsView` body stays within the type-length budget. Same-file, so it still reaches `vm`.
private extension SettingsView {
    /// The "Mode picker" card: the master toggle, plus (when on) the wheel trigger recorder and the
    /// editable direction → mode layout.
    var radialPickerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Mode picker")
            SettingsCard {
                SettingToggleRow(
                    title: "Radial mode picker",
                    subtitle: "Hold a key to pop a wheel at the cursor, then aim (or use an arrow key) "
                        + "to a mode and release to start it - in place of separate per-mode shortcuts.",
                    isOn: Binding(get: { vm.radialEnabled }, set: { vm.radialEnabled = $0 })
                )
                if vm.radialEnabled {
                    Hairline().opacity(0.5)
                    shortcutRow(
                        title: "Wheel trigger",
                        subtitle: "Hold this to show the wheel. A held modifier works best (default left ⌥)."
                    ) {
                        KeyRecorderField(hotkey: vm.radialShortcut) { vm.radialShortcut = $0 }
                    }
                    Hairline().opacity(0.5)
                    dialSizeRow
                    Hairline().opacity(0.5)
                    radialLayoutEditor
                }
            }
        }
    }

    /// Slider for the pop-up dial's size (50%...100% of full).
    var dialSizeRow: some View {
        SettingsRow(title: "Dial size", subtitle: "Shrink the pop-up dial. 100% is full size.") {
            HStack(spacing: 10) {
                Slider(
                    value: Binding(get: { vm.radialScale }, set: { vm.radialScale = $0 }),
                    in: 0.5 ... 1.0, step: 0.05
                )
                .controlSize(.small)
                .tint(Palette.accent)
                .frame(width: 150)
                Text("\(Int((vm.radialScale * 100).rounded()))%")
                    .font(.mono(11))
                    .foregroundStyle(Palette.fg1)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    /// The shortcuts-tab footer, describing whichever launch model is active (wheel vs per-mode chords).
    var shortcutsFooter: String {
        if vm.radialEnabled {
            return "Hold the wheel trigger to pick a mode, then release to start it - the per-mode chords "
                + "below stand down while the wheel is on. Esc stops. The launched mode keeps its own "
                + "options (auto-end on silence, target field, Ask overlay). Modifiers are left/right "
                + "specific (L⌥ vs R⌥). While recording a shortcut, global shortcuts pause so any "
                + "combination can be captured."
        }
        return "Defaults: ⌥ transcribes, ⌥⌃ asks, ⌥⇧ rewrites the selection, ⌃⇧ translates, Esc stops. "
            + "Push to talk records while held (after the optional start delay); Trigger taps on, "
            + "then off; Hold & release long-presses to start and keeps recording -- long-press "
            + "again, press Stop, or (when enabled) pause speaking to finish. Modifiers are "
            + "left/right specific (L⌥ vs R⌥). While recording a shortcut, global shortcuts pause "
            + "so any combination can be captured."
    }

    /// Editable wheel layout: the same radial UI the overlay shows, with each quadrant tappable to
    /// pick its mode (swapping to keep all four reachable). Centered in the card.
    var radialLayoutEditor: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                RadialLayoutWheel(layout: Binding(get: { vm.radialLayout }, set: { vm.radialLayout = $0 }))
                Spacer(minLength: 0)
            }
            Text("Tap a slice to choose what it launches.")
                .font(.sans(10.5))
                .foregroundStyle(Palette.fg3)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}
