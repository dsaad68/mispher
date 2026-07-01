import AppKit
import Combine
import SwiftUI

/// Hosts the SwiftUI ``NotchView`` in AppKit with click-through support: only the active pill / panel
/// rect receives mouse events, everything else passes through. Ported 1:1 from copilot-island.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRect: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitTestRect().contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// Hosts ``NotchView`` and computes its interactive rect per notch state. Ported 1:1 from
/// copilot-island, with the Mispher ``NotchSessionStore`` injected into the view.
final class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private let store: NotchSessionStore
    private var hostingView: PassThroughHostingView<NotchView>!

    init(viewModel: NotchViewModel, store: NotchSessionStore) {
        self.viewModel = viewModel
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        hostingView = PassThroughHostingView(rootView: NotchView(viewModel: viewModel, store: store))
        // The notch window is a fixed, full-screen-width panel sized by its controller; don't let the
        // hosting view auto-resize the window to its SwiftUI content (the macOS 26 default), which can
        // fight the fixed frame and trip a runaway layout pass.
        hostingView.sizingOptions = []

        hostingView.hitTestRect = { [weak self] in
            guard let self else { return .zero }
            let geometry = viewModel.geometry
            let windowHeight = geometry.windowHeight

            switch viewModel.status {
            case .opened:
                let panelSize = viewModel.openedSize
                let panelWidth = panelSize.width + 52
                let panelHeight = panelSize.height
                let screenWidth = geometry.screenRect.width
                return CGRect(
                    x: (screenWidth - panelWidth) / 2,
                    y: windowHeight - panelHeight,
                    width: panelWidth,
                    height: panelHeight
                )
            case .closed, .popping:
                let notchRect = geometry.deviceNotchRect
                let screenWidth = geometry.screenRect.width
                return CGRect(
                    x: (screenWidth - notchRect.width) / 2 - 10,
                    y: windowHeight - notchRect.height - 5,
                    width: notchRect.width + 20,
                    height: notchRect.height + 10
                )
            }
        }

        view = hostingView
    }
}

/// Owns the notch panel: positions it over the notch, wires the view model's status to mouse-event
/// pass-through, and watches for clicks on the notch (to open) and outside it (to close). Ported from
/// copilot-island's `NotchWindowController`; the boot animation is dropped (the notch is shown/hidden
/// by ``AskNotchController`` for the duration of an Ask session rather than living permanently).
final class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    let screen: NSScreen
    private var cancellables = Set<AnyCancellable>()
    // Set only on the main thread; `nonisolated(unsafe)` lets the (nonisolated) deinit remove them.
    private nonisolated(unsafe) var globalClickMonitor: Any?
    private nonisolated(unsafe) var localClickMonitor: Any?

    init(screen: NSScreen, store: NotchSessionStore) {
        self.screen = screen

        let screenFrame = screen.frame
        let hasNotch = screen.safeAreaInsets.top > 0
        let notchWidth: CGFloat = 180
        let notchHeight: CGFloat = hasNotch ? screen.safeAreaInsets.top : 32
        let notchSize = CGSize(width: notchWidth, height: notchHeight)

        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )

        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )

        viewModel = NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            windowHeight: windowHeight,
            hasPhysicalNotch: hasNotch
        )

        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        notchWindow.identifier = NSUserInterfaceItemIdentifier(Self.panelIdentifier)

        super.init(window: notchWindow)

        notchWindow.contentViewController = NotchViewController(viewModel: viewModel, store: store)
        notchWindow.setFrame(windowFrame, display: true)

        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.handleStatusChange(status) }
            .store(in: &cancellables)

        notchWindow.ignoresMouseEvents = true
        setupGlobalEventMonitors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
    }

    /// Window identifier so the HUD window-picking helpers can skip the notch panel.
    static let panelIdentifier = "mispher.askNotch"

    private func handleStatusChange(_ status: NotchStatus) {
        guard let notchWindow = window as? NotchPanel else { return }
        switch status {
        case .opened:
            notchWindow.ignoresMouseEvents = false
            // Become key while open so the Ask composer's text field can receive keyboard input
            // (a non-activating panel becomes key without activating the app).
            notchWindow.makeKey()
        case .closed, .popping:
            notchWindow.ignoresMouseEvents = true
        }
    }

    /// The notch rect in screen coordinates (for hit-testing global clicks).
    private var notchScreenRect: CGRect {
        let screenFrame = screen.frame
        let notchRect = viewModel.deviceNotchRect
        let padding: CGFloat = 10
        return CGRect(
            x: screenFrame.origin.x + (screenFrame.width - notchRect.width) / 2 - padding,
            y: screenFrame.maxY - notchRect.height - padding,
            width: notchRect.width + padding * 2,
            height: notchRect.height + padding * 2
        )
    }

    /// The opened panel's interactive rect in screen coordinates - the `NotchViewController`
    /// hit-test rect (panel size + the 52pt ear margin), converted from window space. Used to decide
    /// whether a click landed on the open notch, in the same global coordinate space as
    /// `NSEvent.mouseLocation`, so the test holds regardless of which window received the event.
    private var openedContentScreenRect: CGRect {
        let screenFrame = screen.frame
        let size = viewModel.openedSize
        let width = size.width + 52
        return CGRect(
            x: screenFrame.origin.x + (screenFrame.width - width) / 2,
            y: screenFrame.maxY - size.height,
            width: width,
            height: size.height
        )
    }

    private func setupGlobalEventMonitors() {
        // Monitor callbacks are delivered on the main thread, so assuming isolation is safe.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleGlobalClick() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalClick() }
            return event
        }
    }

    /// A click that landed outside our windows (delivered to another app, the desktop, or the menu
    /// bar). While closed, open the notch if the click hit it; while open, collapse it - a global click
    /// by definition didn't hit the notch content (that would be consumed by our panel and arrive at
    /// the *local* monitor instead), so "click anywhere outside closes it" is now consistent.
    private func handleGlobalClick() {
        switch viewModel.status {
        case .closed, .popping:
            if notchScreenRect.contains(NSEvent.mouseLocation) { viewModel.notchOpen(reason: .click) }
        case .opened:
            viewModel.notchClose()
        }
    }

    /// A click routed to one of *our* windows. While the notch is closed it reopens on a click that
    /// lands on the notch (the global monitor only sees clicks that pass through to other apps, so a
    /// click landing on a Mispher window sitting behind the closed pill would otherwise be missed).
    /// While the notch is open it closes unless the click hit the open panel. We test the click's
    /// *screen* location against the panel rect rather than hit-testing the notch's `contentView`
    /// with the event's `locationInWindow`: a click routed to a *different* Mispher window (the HUD,
    /// a recording overlay) carries that window's coordinates, which mismatch the notch's content
    /// view and used to keep the notch wrongly open - the "click outside sometimes doesn't close" bug.
    private func handleLocalClick() {
        if viewModel.status == .closed || viewModel.status == .popping {
            if notchScreenRect.contains(NSEvent.mouseLocation) { viewModel.notchOpen(reason: .click) }
            return
        }
        guard viewModel.status == .opened else { return }
        if !openedContentScreenRect.contains(NSEvent.mouseLocation) { viewModel.notchClose() }
    }
}
