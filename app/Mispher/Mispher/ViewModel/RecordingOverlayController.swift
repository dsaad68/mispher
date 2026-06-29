import AppKit
import Observation
import SwiftUI

/// Owns the compact recording overlay (the floating-notch pill, floating panel, or Dynamic Island)
/// shown while dictating when the user picks a non-window presentation. A borderless, non-activating
/// panel -- so it floats over other apps (and fullscreen) without stealing the focused
/// text field's caret, which the transcript insert depends on.
///
/// Visibility and position track the view model's recording state via `withObservationTracking`;
/// the live transcript is rendered by the hosted SwiftUI view observing the same model, so the
/// text updates as it streams in with no extra plumbing.
@MainActor
final class RecordingOverlayController {
    /// Window identifier so the HUD window-picking helpers can skip the overlay panel.
    static let panelIdentifier = "mispher.recordingOverlay"

    private var viewModel: TranscriptionViewModel?
    private var panel: NSPanel?
    /// Backs the floating Ask card (Floating notch / Floating presentations) with the same
    /// presentation-agnostic store the notch island uses; bound once on ``attach(_:mlx:)``.
    private let store = NotchSessionStore()
    /// The floating Ask card reports its measured height here so the panel can size to it (the card
    /// grows stage by stage like the island, with no transparent click-blocking dead zone).
    private let askLayout = FloatingAskLayout()
    /// The presentation that was active when the panel was last shown; used in `hide()` to decide
    /// whether to play the Dynamic Island collapse animation (rather than re-reading the live
    /// setting, which may have changed by the time `hide()` fires).
    private var shownPresentation: RecordingPresentation?

    /// Remembered position of the floating card, persisted so it reappears wherever the user last
    /// dragged it (rather than snapping back to a default each session).
    private var floatingOrigin: NSPoint? = RecordingOverlayController.loadFloatingOrigin() {
        didSet { if let floatingOrigin, floatingOrigin != oldValue { Self.saveFloatingOrigin(floatingOrigin) } }
    }

    /// Drives the Dynamic Island's expand/collapse animation, kept separate from the recording
    /// state so the island can finish collapsing before its panel is ordered out.
    private let island = IslandPresenter()
    /// Pending "expand the island out of the notch" work (deferred a frame so the open animates).
    private var expandTask: Task<Void, Never>?
    /// Pending "order the island panel out" work, run after the collapse animation has played.
    private var hideTask: Task<Void, Never>?
    /// How long the collapse animation runs before the Dynamic Island panel is hidden.
    private static let islandCollapseDuration: TimeInterval = 0.42
    /// `UserDefaults` key for the persisted floating-card position.
    private nonisolated static let floatingOriginKey = "mispher.floatingOverlayOrigin"

    /// Wire the controller to the model and begin tracking its recording state. Idempotent so it
    /// can be called again when the main window reopens.
    func attach(_ vm: TranscriptionViewModel, mlx: MlxModelManager) {
        guard viewModel == nil else { sync(); return }
        viewModel = vm
        store.bind(viewModel: vm, mlx: mlx)
        track()
        sync()
    }

    // MARK: - Observation

    /// One-shot observation of the fields that decide whether/where the overlay shows; re-armed
    /// after every change.
    private func track() {
        withObservationTracking {
            guard let vm = viewModel else { return }
            _ = vm.state
            _ = vm.recordingPresentation
            _ = vm.askPresentation
            _ = vm.activeIntent
            _ = vm.isCleaningUp // keep the overlay up through the AI cleanup pass (state is idle then)
            _ = vm.isRewriting // ditto through rewrite generation (also runs with state idle)
            _ = vm.isTranslating // ditto through the translation pass
            _ = vm.askOverlaySessionActive // sticky Ask conversation: stays up between turns
            _ = askLayout.contentHeight // resize the floating Ask card as the conversation grows
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.track()
            }
        }
    }

    /// Show + position the overlay when a recording session is live in a non-window presentation;
    /// hide it otherwise. Ask uses its own ``askPresentation`` setting; voice modes use ``recordingPresentation``.
    private func sync() {
        guard let vm = viewModel else { hide(); return }
        let isAsk = vm.activeIntent == .ask
        let presentation = isAsk ? vm.askPresentation : vm.recordingPresentation
        // Dictation and Rewrite write into the frontmost app, so they use the compact overlay during
        // their session phases. Ask is different: in a roomier form (floating / dynamic island) it
        // runs as a sticky multi-turn conversation that persists between turns until dismissed; in
        // the notch pill or main window it still answers in the HUD and uses no overlay.
        let visible: Bool
        if isAsk {
            // Ask on the Dynamic Island is hosted by the ported copilot-island notch
            // (``AskNotchController``); this controller still hosts Ask on the floating card.
            visible = vm.askOverlaySupported && vm.askOverlaySessionActive && presentation != .dynamicIsland
        } else {
            visible = presentation != .mainWindow && vm.isOverlayPhase
        }
        if visible {
            show(presentation: presentation)
        } else {
            hide()
        }
    }

    // MARK: - Window

    private func show(presentation: RecordingPresentation) {
        shownPresentation = presentation
        cancelPendingTransitions()
        let panel = panel ?? makePanel()
        self.panel = panel
        let isAsk = viewModel?.activeIntent == .ask
        let size = panelSize(for: presentation, ask: isAsk)
        if panel.frame.size != size { panel.setContentSize(size) }
        position(panel, for: presentation, size: size, ask: isAsk)
        panel.isMovableByWindowBackground = (presentation == .floating)
        // The notch pill and Dynamic Island are pure status displays with no controls, so let clicks
        // pass straight through to the app underneath -- no dead zone, even when the panel is sized
        // for three lines but only one is showing. The Ask card is interactive (scroll, approval and
        // close buttons), so it must receive clicks on every form.
        panel.ignoresMouseEvents = !isAsk && (presentation == .floatingNotch || presentation == .dynamicIsland)
        // Ask is an interactive surface -- you can type a follow-up -- so its panel must be able to
        // become the key window or the composer's SwiftUI text field can't take first responder and
        // typed keys go nowhere. The dictation pill/island stay non-key so they never steal the
        // focused app's caret, which transcript insertion depends on.
        panel.becomesKeyOnlyIfNeeded = !isAsk
        if !panel.isVisible {
            // The Dynamic Island starts collapsed so it can animate out of the notch on first show.
            if presentation == .dynamicIsland { island.expanded = false }
            panel.orderFrontRegardless()
            // Make the Ask card key on appearance (a non-activating panel becomes key without
            // activating the app), so its message box is ready to type into right away.
            if isAsk { panel.makeKey() }
        }
        if presentation == .dynamicIsland {
            // Defer a frame so the collapsed state renders before we expand -- that lets the spring
            // animate the island *out of the notch* instead of snapping straight to full size.
            expandTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled else { return }
                self?.island.expanded = true
            }
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        if panel.isMovableByWindowBackground { floatingOrigin = panel.frame.origin }
        cancelPendingTransitions()
        if shownPresentation == .dynamicIsland {
            // Collapse the island back into the notch, then order the panel out once it has played.
            island.expanded = false
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.islandCollapseDuration))
                guard !Task.isCancelled else { return }
                self?.shownPresentation = nil
                self?.panel?.orderOut(nil)
            }
        } else {
            shownPresentation = nil
            panel.orderOut(nil)
        }
    }

    /// Cancel any in-flight Dynamic Island open/close animation steps (a new session can start while
    /// the previous one is still collapsing, and vice versa).
    private func cancelPendingTransitions() {
        expandTask?.cancel(); expandTask = nil
        hideTask?.cancel(); hideTask = nil
    }

    private func makePanel() -> NSPanel {
        let panel = KeyableOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(Self.panelIdentifier)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the SwiftUI pill/card draws its own shadow
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        if let vm = viewModel {
            // Inject the model manager too: the Ask conversation card reads the shared chat thread
            // (transcript, generating state, pending approval) from it. Set at app launch, so it's
            // present before any overlay shows.
            let host = NSHostingView(
                rootView: RecordingOverlayRoot()
                    .environment(vm).environment(island).environment(vm.mlxModels)
                    .environmentObject(store).environment(askLayout)
            )
            host.sizingOptions = []
            // The controller is the sole authority on this panel's size (it sets it from the Ask
            // card's measured height). When an NSHostingView is a window's *contentView* it also
            // drives the window size to follow its content (`updateAnimatedWindowSize`); on macOS 26
            // that fights the controller's `setContentSize` and the window never settles, tripping
            // AppKit's "more Update Constraints passes than views" exception. Hosting it inside a plain
            // container view (so it's a subview, not the contentView) stops it from resizing the window.
            let container = NSView()
            container.autoresizesSubviews = true
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            panel.contentView = container
            host.frame = container.bounds
        }
        return panel
    }

    // MARK: - Geometry

    /// The floating Ask card panel width: the card plus its shadow insets on each side.
    private var floatingAskWidth: CGFloat { FloatingAskView.cardWidth + FloatingAskView.shadowInset * 2 }

    /// The floating Ask card panel height, tracking the card's measured content so it grows stage by
    /// stage. Clamped to a sane range, with a small fallback before the first measurement lands.
    private var floatingAskHeight: CGFloat {
        let measured = askLayout.contentHeight
        let height = measured > 0 ? measured : 120
        return min(max(height, 80), 480).rounded()
    }

    private func panelSize(for presentation: RecordingPresentation, ask: Bool) -> NSSize {
        // The Ask conversation card needs room for the latest exchange (question + streaming answer,
        // condensed agent timeline, and any approval card), so it's taller than the dictation pill.
        if ask {
            switch presentation {
            // The floating Ask card sizes to its content (see ``floatingAskHeight``) so it grows stage
            // by stage like the notch island; both floating forms share the card.
            case .floating, .floatingNotch: return NSSize(width: floatingAskWidth, height: floatingAskHeight)
            case .dynamicIsland: return NSSize(width: 384, height: 420) // hosted by AskNotchController, not here
            case .mainWindow: break // Ask not hosted here; fall through to pill sizes
            }
        }
        switch presentation {
        case .floating: return NSSize(width: 380, height: 116) // pill + room for its free-floating shadow
        case .dynamicIsland: return NSSize(width: 384, height: 150)
        case .floatingNotch: return NSSize(width: 360, height: 86) // tall enough for three lines
        case .mainWindow: return NSSize(width: 360, height: 48)
        }
    }

    private func position(_ panel: NSPanel, for presentation: RecordingPresentation, size: NSSize, ask: Bool) {
        guard let screen = targetScreen() else { return }
        let visible = screen.visibleFrame
        switch presentation {
        case .floatingNotch:
            // Pin just under the notch (or the menu bar on notch-less displays), centered. The top edge
            // is `maxY - inset - 4` regardless of height, so the Ask card grows downward from there.
            let inset = max(screen.safeAreaInsets.top, screen.frame.maxY - visible.maxY)
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.maxY - inset - size.height - 4
            panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        case .dynamicIsland:
            // Flush to the top of the screen so the island's black reaches up behind the notch; the
            // content is inset below the notch by `island.notchInset` (set here from the screen).
            island.notchInset = max(screen.safeAreaInsets.top, screen.frame.maxY - visible.maxY)
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.maxY - size.height
            panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        case .floating:
            // A free-floating card: movable by its background, it can sit anywhere on the desktop.
            // Keep a live drag (so a re-position mid-session doesn't yank it) before deciding where
            // it goes; the chosen origin is clamped on-screen for a since-removed display or a
            // pointer sitting at a screen edge.
            // While the Ask card is up it resizes as the conversation grows: hold the *top* edge fixed
            // so it grows downward rather than creeping upward from the window's bottom-left origin.
            if ask, panel.isVisible {
                let top = panel.frame.maxY
                placeFloating(panel, origin: NSPoint(x: panel.frame.minX, y: top - size.height), size: size, in: visible)
                return
            }
            if panel.isVisible { floatingOrigin = panel.frame.origin }
            var origin: NSPoint
            if viewModel?.floatingFollowsPointer == true, !panel.isVisible {
                // "Appear near the pointer": drop the card just below the cursor each time it appears
                // (its top tucked under the pointer), then grow downward. The top padding keeps it clear.
                let mouse = NSEvent.mouseLocation
                origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 8)
            } else {
                // Otherwise centre it the first time, then leave it wherever the user last dragged it.
                origin = floatingOrigin
                    ?? NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            }
            placeFloating(panel, origin: origin, size: size, in: visible)
        case .mainWindow:
            break
        }
    }

    /// Clamp `origin` so the whole panel stays within `visible`, then move it there.
    private func placeFloating(_ panel: NSPanel, origin: NSPoint, size: NSSize, in visible: NSRect) {
        var origin = origin
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: origin.x.rounded(), y: origin.y.rounded()))
    }

    /// The screen the overlay should appear on: the key window's screen, else the one under the
    /// pointer, else main. (Never blindly `screens.first` -- it isn't necessarily the active one.)
    private func targetScreen() -> NSScreen? {
        NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    private nonisolated static func saveFloatingOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: floatingOriginKey)
    }

    private nonisolated static func loadFloatingOrigin() -> NSPoint? {
        guard let xy = UserDefaults.standard.array(forKey: floatingOriginKey) as? [Double], xy.count == 2
        else { return nil }
        return NSPoint(x: xy[0], y: xy[1])
    }
}

/// A borderless overlay panel that is still allowed to become key. A plain borderless `NSPanel`
/// returns `canBecomeKey == false`, which silently blocks keyboard focus -- so the Ask card's text
/// field can never take first responder and typing does nothing (this is why the Dynamic Island,
/// whose ``NotchPanel`` overrides `canBecomeKey`, worked while the floating card didn't). The
/// dictation pill never calls `makeKey`, so allowing key here doesn't make it steal focus.
private final class KeyableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Animation state for the Dynamic Island overlay. The controller flips `expanded` to drive the
/// spring that grows the island out of the notch (on show) and collapses it back (on hide); the
/// SwiftUI island view observes it.
@MainActor @Observable
final class IslandPresenter {
    var expanded = false
    /// Height of the notch / menu bar on the island's screen. The island's content sits below this
    /// (so the hardware notch never clips it) while its black background reaches up behind the
    /// notch, giving the "grows out of the notch" look that sets it apart from the floating notch.
    var notchInset: CGFloat = 0
}
