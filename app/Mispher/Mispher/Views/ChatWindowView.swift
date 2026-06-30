import AppKit
import SwiftUI

/// The app's primary window: a frosted-glass panel hosting the chat, with a collapsible left rail of
/// past conversations (hidden by default). Replaces the old transcription HUD (``ContentView``) - the
/// transcript + record controls are gone; dictation now happens via the composer mic and the global
/// shortcuts' compact overlays. Carries the first-run onboarding open and the menu-bar -> window
/// notification bridges the old HUD hosted.
struct ChatWindowView: View {
    @Environment(TranscriptionViewModel.self) private var vm
    @Environment(\.openWindow) private var openWindow

    @State private var sidebarVisible = false

    private let corner: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            // Reserve the draggable titlebar band so the content clears the traffic-light buttons.
            Color.clear.frame(height: 22)

            HStack(spacing: 0) {
                if sidebarVisible {
                    ConversationSidebarView()
                        .frame(width: 240)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
                }
                VStack(spacing: 0) {
                    ChatHeaderView(sidebarVisible: $sidebarVisible)
                    ChatView()
                }
            }
        }
        .background(VisualEffectView(material: .hudWindow))
        .overlay(alignment: .top) {
            // Signature hairline accent edge along the very top of the glass.
            LinearGradient(
                colors: [.clear, Palette.accent.opacity(0.45), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 28)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        }
        .background(GlassWindowConfigurator())
        .ignoresSafeArea()
        .frame(minWidth: 440, minHeight: 500)
        .preferredColorScheme(.dark)
        .onAppear { vm.onAppear() }
        // First launch: open the welcome / setup wizard. Deferred a beat (a synchronous `openWindow`
        // during the window's initial appear can silently no-op before the scene system is ready). The
        // wizard marks onboarding complete when it appears, so this fires exactly once.
        .task {
            guard !vm.hasCompletedOnboarding else { return }
            try? await Task.sleep(for: .milliseconds(200))
            // The app launches menu-bar-only (accessory) with the chat window hidden, so surface it
            // with a Dock icon and focus before opening the wizard - otherwise the Welcome window would
            // appear unfocused behind other apps. Onboarding's "finish" brings the chat window forward.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: MispherApp.onboardingWindowID)
        }
        // The menu bar item's "Settings…" routes here, since only SwiftUI can open the scene. This view
        // stays alive (the window is hidden, not closed) in menu-bar mode, so it keeps receiving these.
        .onReceive(NotificationCenter.default.publisher(for: .mispherShowSettings)) { _ in
            openWindow(id: MispherApp.settingsWindowID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mispherShowOnboarding)) { _ in
            openWindow(id: MispherApp.onboardingWindowID)
        }
    }
}
