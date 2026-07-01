import AppKit
import Observation
import SwiftUI

/// Selection + visibility state for the radial mode picker, observed by ``RadialMenuView``. Kept
/// separate from the recording view model (like ``IslandPresenter``) so the wheel animates on its
/// own without entangling the session state.
@MainActor @Observable
final class RadialMenuPresenter {
    /// Whether the wheel is on screen (drives the appear/disappear spring).
    var shown = false
    /// The highlighted slot, or `nil` when the pointer sits in the center dead-zone (release cancels).
    var highlighted: RadialDirection?
    /// The direction → mode mapping to render, snapshotted from the user's setting on each open.
    var layout = RadialLayout.default
    /// The dial's size as a fraction of full (0.5...1.0), snapshotted on each open.
    var scale: CGFloat = 1
    /// Whether the Ask slice is split into New / Continue (snapshotted on open: true when an Ask
    /// conversation is open to resume). When false the Ask slice is a single wedge that starts fresh.
    var askSplit = false
    /// The half of the split Ask slice currently aimed at; only meaningful while ``highlighted`` is the
    /// Ask direction and ``askSplit`` is true.
    var askChoice: RadialAskChoice = .new
}

/// Owns the radial mode picker overlay: a borderless, click-through, non-activating panel centered on
/// the cursor while the trigger is held. ``HotKeyTap`` drives it -- ``open()`` on a clean trigger
/// hold, ``handleArrow(_:)`` from arrow keys, ``close()`` on release (commit), ``cancel()`` on a
/// forced abort. Pointer aim is tracked with the controller's own mouse-moved monitors (the trigger
/// button is not down, so this is plain pointer motion, not a drag), keeping those high-frequency
/// events out of the global event tap. Mirrors ``RecordingOverlayController``'s panel recipe.
@MainActor
final class RadialMenuController {
    /// Window identifier so HUD window-picking helpers can skip this panel.
    static let panelIdentifier = "mispher.radialMenu"

    private var viewModel: TranscriptionViewModel?
    private var panel: NSPanel?
    private let presenter = RadialMenuPresenter()
    private var mouseMonitors: [Any] = []

    /// Square panel side: the wheel (236) plus enough transparent margin that its soft drop shadow
    /// (``RadialMenuView`` casts radius 24, y 14) fully fades *before* the panel edge. Sized too tight
    /// and the borderless panel clips the shadow into a hard-edged box around the dial.
    private static let panelSide: CGFloat = 340
    /// Aim inside this radius (points) selects nothing, so a release there cancels.
    private static let deadZone: CGFloat = 30

    /// Wheel center in *screen* coordinates, captured when it opens. Aim is measured from here -- not
    /// the panel's (possibly edge-clamped) frame center -- so directions stay correct near edges.
    private var center: NSPoint = .zero
    /// The dial's size fraction (0.5...1.0), captured on open; scales the dead-zone with the visuals.
    private var scale: CGFloat = 1
    /// The direction the Ask slice occupies, captured on open so the sub-split (New / Continue) is read
    /// only while the aim is over Ask -- independent of where the user mapped Ask in their layout.
    private var askDirection: RadialDirection = RadialLayout.default.direction(of: .ask)

    func attach(_ vm: TranscriptionViewModel) { viewModel = vm }

    // MARK: - Lifecycle driven by HotKeyTap

    /// Show the wheel centered on the cursor and start tracking pointer motion.
    func open() {
        guard let viewModel else { return }
        center = NSEvent.mouseLocation
        scale = CGFloat(viewModel.radialScale)
        askDirection = viewModel.radialLayout.direction(of: .ask)
        presenter.highlighted = nil
        presenter.layout = viewModel.radialLayout
        presenter.scale = scale
        // Offer New / Continue on the Ask slice only when there's a conversation to resume.
        presenter.askSplit = viewModel.hasResumableAskConversation
        presenter.askChoice = .new
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        presenter.shown = true
        if !panel.isVisible { panel.orderFrontRegardless() }
        installMouseMonitors()
    }

    /// Trigger released: launch the highlighted slot's mode, or just dismiss if the aim was in the
    /// dead-zone (no selection).
    func close() {
        let selection = presenter.highlighted
        let choice = presenter.askChoice
        let split = presenter.askSplit
        teardownMonitors()
        hide()
        guard let selection, let vm = viewModel else { return }
        let mode = vm.radialLayout.mode(at: selection)
        // On the split Ask slice the aimed half decides New vs Continue; every other slot (and a whole
        // Ask slice) launches its mode's default intent.
        vm.startRadialMode(mode == .ask && split ? choice.intent : mode.intent)
    }

    /// Force the wheel down without launching anything (config push / teardown / disable mid-hold).
    func cancel() {
        teardownMonitors()
        hide()
    }

    /// Move the highlight from an arrow key (forwarded by ``HotKeyTap`` while the wheel is open).
    /// Arrowing onto a split Ask slice defaults to New (the primary action); the Continue half is
    /// reached by pointer aim (or the dedicated ``TranscriptionViewModel/askContinueShortcut``).
    func handleArrow(_ direction: RadialDirection) {
        presenter.highlighted = direction
        if direction == askDirection, presenter.askSplit { presenter.askChoice = .new }
    }

    // MARK: - Pointer tracking

    private func installMouseMonitors() {
        teardownMonitors()
        // Global: pointer over other apps (the common case -- our panel is click-through and
        // non-activating, so the foreground app keeps focus). Local: pointer over our own windows.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            self?.updateHighlightFromPointer()
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.updateHighlightFromPointer()
            return event
        }) {
            mouseMonitors.append(local)
        }
        updateHighlightFromPointer()
    }

    private func teardownMonitors() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
    }

    private func updateHighlightFromPointer() {
        let point = NSEvent.mouseLocation
        let dx = point.x - center.x, dy = point.y - center.y
        let direction = RadialDirection.from(dx: dx, dy: dy, deadZone: Self.deadZone * scale)
        presenter.highlighted = direction
        // Within the split Ask slice, the aim angle picks New vs Continue.
        if direction == askDirection, presenter.askSplit {
            presenter.askChoice = RadialAskChoice.from(dx: dx, dy: dy, wedge: askDirection)
        }
    }

    // MARK: - Window

    private func hide() {
        presenter.shown = false
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let side = Self.panelSide
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(Self.panelIdentifier)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the SwiftUI wheel draws its own shadow
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Click-through: the wheel is a pure pointer-aim HUD, so the cursor still drives the app
        // underneath; aim is read from mouse-moved monitors, not panel hit-testing.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Host SwiftUI inside a plain container (not as contentView) so it can't drive the panel size
        // -- same macOS 26 sizing work-around as RecordingOverlayController.
        let host = NSHostingView(rootView: RadialMenuView().environment(presenter))
        host.sizingOptions = []
        let container = NSView()
        container.autoresizesSubviews = true
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        host.frame = container.bounds
        return panel
    }

    private func position(_ panel: NSPanel) {
        let side = Self.panelSide
        var origin = NSPoint(x: center.x - side / 2, y: center.y - side / 2)
        // Clamp the panel fully on-screen; the aim math keeps using the true cursor `center`, so a
        // clamped panel near an edge still reads directions correctly.
        if let screen = targetScreen() {
            let frame = screen.frame
            origin.x = min(max(origin.x, frame.minX), frame.maxX - side)
            origin.y = min(max(origin.y, frame.minY), frame.maxY - side)
        }
        panel.setFrameOrigin(NSPoint(x: origin.x.rounded(), y: origin.y.rounded()))
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? NSApp.keyWindow?.screen ?? NSScreen.main
    }
}
