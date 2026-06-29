import AppKit
import DeepAgents
import DeepAgentsMLX
import SwiftUI

/// The first-run welcome / setup wizard, shown once on first launch and re-runnable any time from
/// the menu bar's "Run setup again". It walks a new user through the essentials in order - ASR
/// model, recording window, then the model + shortcut for transcription, rewrite, translate, and
/// ask - and finally points at MCP / middleware for power users. Every choice writes straight to
/// ``TranscriptionViewModel`` (which persists it), so there's nothing to "save": the wizard is just
/// a guided lens over the same settings, and closing it part-way keeps whatever was set. Deeper
/// tuning (prompts, timing, dictionaries) stays in Settings.
struct OnboardingView: View {
    @Environment(TranscriptionViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var step: OnboardingStep = .welcome

    /// The window is a fixed size (locked in ``OnboardingWindowConfigurator``): the header and footer
    /// stay pinned, and only the middle scrolls when a step's content is taller than the area between
    /// them. The root fills the whole window so the frosted background always covers it edge to edge -
    /// no native window backing can show through as a grey strip.
    static let contentWidth: CGFloat = 580
    static var windowHeight: CGFloat {
        min(750, max(440, (NSScreen.main?.visibleFrame.height ?? 680) - 40))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Reserve a titlebar band so the window's traffic lights clear the header (this is a
            // hidden-titlebar window, like Settings).
            Color.clear.frame(height: 28)
            if step == .welcome {
                welcomeHero
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Rectangle().fill(Palette.border).frame(height: 1)
                stepBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            footer
        }
        // Fill the whole window so the background below covers every pixel, even if the window frame
        // is a hair taller than the content column.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                VisualEffectView(material: .hudWindow)
                Palette.glassFill.opacity(0.5)
            }
            .ignoresSafeArea()
        }
        .background(OnboardingWindowConfigurator())
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        // Shown once: marking it complete here means the first-run auto-open never fires again,
        // while "Run setup again" can still reopen it without clearing the flag.
        .onAppear { vm.hasCompletedOnboarding = true }
        .task { await vm.refreshDownloadStates() }
    }

    // MARK: Welcome hero (first view)

    private var welcomeHero: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 16)
            BrandMarkView(size: 54)
            Text("Welcome to Mispher!")
                .font(.title(36, weight: .semibold))
                .foregroundStyle(Palette.fg)
                .multilineTextAlignment(.center)
            Text("Your private, on-device transcription and voice-activated agents - dictate, "
                + "rewrite, translate, and ask, deeply customizable and with nothing ever leaving your Mac.")
                .font(.sans(13))
                .foregroundStyle(Palette.fg2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430)
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 48)
    }

    // MARK: Header (per-step)

    private var header: some View {
        HStack(spacing: 11) {
            BrandMarkView(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.title(20, weight: .semibold))
                    .foregroundStyle(Palette.fg)
                Text(step.subtitle)
                    .font(.sans(11.5))
                    .foregroundStyle(Palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    /// One dot per step, the current one elongated + accent and visited ones dimmed - a light
    /// "where am I" cue. Lives in the footer, centered between Back and the primary action.
    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { item in
                Capsule()
                    .fill(item == step ? Palette.accent : Palette.fg3.opacity(item.rawValue < step.rawValue ? 0.7 : 0.3))
                    .frame(width: item == step ? 16 : 6, height: 6)
                    .animation(.easeOut(duration: 0.18), value: step)
            }
        }
    }

    // MARK: Content

    private var stepBody: some View {
        // The scroll lives between the static header and footer; it fills the fixed middle and only
        // actually scrolls when a step's content is taller than that area.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stepContent
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome: EmptyView() // handled by `welcomeHero`
        case .asr: OnboardingAsrStep()
        case .microphone: OnboardingMicrophoneStep()
        case .presentation: OnboardingPresentationStep()
        case .control: OnboardingControlStep()
        case .cleanup: OnboardingCleanupStep()
        case .rewrite: OnboardingRewriteStep()
        case .translate: OnboardingTranslateStep()
        case .ask: OnboardingAskStep()
        case .power: OnboardingPowerStep()
        case .finish: OnboardingFinishStep()
        }
    }

    // MARK: Footer (navigation + progress)

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                Button("Back") { goBack() }
                    .buttonStyle(GlassPillButtonStyle())
            }
            Spacer(minLength: 8)
            progressDots
            Spacer(minLength: 8)
            if step.isSkippable {
                Button("Skip") { goNext() }
                    .buttonStyle(.plain)
                    .font(.sans(11.5, weight: .medium))
                    .foregroundStyle(Palette.fg2)
            }
            primaryButton
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Start") { goNext() }
                .buttonStyle(GlassPillButtonStyle(prominent: true))
        case .finish:
            Button("Done") { finish() }
                .buttonStyle(GlassPillButtonStyle(prominent: true))
        default:
            Button("Continue") { goNext() }
                .buttonStyle(GlassPillButtonStyle(prominent: true))
        }
    }

    // MARK: Navigation

    private func goNext() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { finish(); return }
        withAnimation(.easeOut(duration: 0.18)) { step = next }
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        withAnimation(.easeOut(duration: 0.18)) { step = previous }
    }

    private func finish() {
        // Return to the menu bar without surfacing the chat, then close the wizard. The app was
        // activated to `.regular` only to show this wizard over the (held-hidden) chat window; the
        // app delegate now drops the Dock icon and keeps the chat hidden. The user opens the chat
        // later from the menu bar's "Open Chat". Settings are already persisted live.
        NotificationCenter.default.post(name: .mispherHideToMenuBar, object: nil)
        dismiss()
    }
}

/// The wizard's steps, in the order the user asked for. `rawValue` drives forward / back navigation
/// and the progress dots.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, asr, microphone, presentation, control, cleanup, rewrite, translate, ask, power, finish

    var id: Int { rawValue }

    /// Cleanup / rewrite / translate / ask / power are optional features, so their steps offer a "Skip".
    var isSkippable: Bool {
        switch self {
        case .cleanup, .rewrite, .translate, .ask, .power: return true
        case .welcome, .asr, .microphone, .presentation, .control, .finish: return false
        }
    }

    var title: String {
        switch self {
        case .welcome: return "Welcome to Mispher"
        case .asr: return "Choose a speech model"
        case .microphone: return "Microphone & access"
        case .presentation: return "Recording window"
        case .control: return "How you control Mispher"
        case .cleanup: return "Dictation cleanup"
        case .rewrite: return "Rewrite by voice"
        case .translate: return "Translate"
        case .ask: return "Ask"
        case .power: return "Power features"
        case .finish: return "You're all set"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return "A quick setup to get you dictating, rewriting, translating, and asking by voice."
        case .asr: return "Pick the on-device model that turns your speech into text, and download it."
        case .microphone: return "Pick your input device and grant the access Mispher needs to record and run shortcuts."
        case .presentation: return "How overlays appear while recording. Voice modes and Ask can use different styles."
        case .control: return "Use the radial dial, or set an individual shortcut per mode."
        case .cleanup: return "Polish your dictation on-device after you stop speaking. Optional."
        case .rewrite: return "Highlight text anywhere, then speak an edit to replace it in place. Optional."
        case .translate: return "Translate your speech into another language as you go. Optional."
        case .ask: return "Send your speech to an on-device model or agent for an answer. Optional."
        case .power: return "Fine-tune your shortcuts, and connect MCP tools and middleware for the agent."
        case .finish: return "Everything's saved. You can change any of this later in Settings."
        }
    }
}

/// Configures the Welcome window like Settings (native, hidden-titlebar, dark) and pins it to a fixed,
/// non-resizable size. Disabling frame restoration stops a stale autosaved frame from leaving slack
/// under the content; pinning the backing to the deep glass colour is a final guard against any grey
/// edge ever showing through.
private struct OnboardingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let proxy = NSView()
        DispatchQueue.main.async {
            guard let window = proxy.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.resizable) // fixed size; the middle scrolls instead
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.isMovableByWindowBackground = false
            window.isRestorable = false
            window.setFrameAutosaveName("") // don't restore a stale frame from a prior run
            window.isOpaque = true
            window.backgroundColor = NSColor(Palette.bgDeep)
            window.setContentSize(NSSize(width: OnboardingView.contentWidth, height: OnboardingView.windowHeight))
            window.center()
            window.level = .normal
            // The app was just flipped from `.accessory` to `.regular` to show the wizard; surface it
            // above other apps now that the window exists (order-front-regardless + re-assert).
            window.surfaceAboveOtherApps()
        }
        return proxy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
