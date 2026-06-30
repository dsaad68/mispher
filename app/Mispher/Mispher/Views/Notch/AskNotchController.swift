import AppKit
import Observation

/// Owns the ported copilot-island notch for the Ask / DeepAgent flow. It mirrors how
/// ``RecordingOverlayController`` is wired (observe the view model, show/hide a borderless panel), but
/// stands alone. In the **Dynamic Island** presentation the notch lives for the whole app session as a
/// collapsed pill - present from launch, so it's always there to click - and pops open while an Ask
/// overlay session is active. It stands down while a non-Ask dictation session shows *its* island
/// (``RecordingOverlayController``) so two shapes don't stack at the notch, and is hidden entirely in
/// the other presentations (which route Ask to ``RecordingOverlayController``).
@MainActor
final class AskNotchController {
    private let store = NotchSessionStore()
    private var windowController: NotchWindowController?
    private weak var viewModel: TranscriptionViewModel?
    private weak var mlx: MlxModelManager?
    /// Tracks the Ask-session edge so the notch pops open when a session starts and collapses to the
    /// pill when it ends, without fighting the user's manual open/close in between.
    private var wasAskActive = false

    /// Wire the controller to the shared models and begin tracking. Idempotent.
    func attach(_ viewModel: TranscriptionViewModel, mlx: MlxModelManager) {
        guard self.viewModel == nil else { sync(); return }
        self.viewModel = viewModel
        self.mlx = mlx
        store.bind(viewModel: viewModel, mlx: mlx)
        track()
        sync()
    }

    // MARK: - Observation

    private func track() {
        withObservationTracking {
            guard let viewModel else { return }
            _ = viewModel.askPresentation
            _ = viewModel.recordingPresentation // needed for the non-Ask dictation conflict guard
            _ = viewModel.activeIntent
            _ = viewModel.askOverlaySessionActive
            _ = viewModel.isOverlayPhase // a non-Ask dictation island temporarily takes the notch over
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.track()
            }
        }
    }

    private func sync() {
        guard let viewModel else { hide(); return }
        // The Ask notch only lives when Ask is configured to use Dynamic Island.
        guard viewModel.askPresentation == .dynamicIsland else { hide(); return }
        // Stand down while a non-Ask dictation session is showing its own Dynamic Island overlay.
        guard !(viewModel.activeIntent != .ask && viewModel.isOverlayPhase
            && viewModel.recordingPresentation == .dynamicIsland) else { hide(); return }

        showWindow()
        let askActive = viewModel.activeIntent == .ask && viewModel.askOverlaySessionActive
        if askActive, !wasAskActive {
            windowController?.viewModel.notchOpen(reason: .notification)
        } else if !askActive, wasAskActive {
            windowController?.viewModel.notchClose()
        }
        wasAskActive = askActive
    }

    // MARK: - Window

    /// Ensure the notch panel exists for the current screen and is on screen (collapsed unless an
    /// Ask session pops it open).
    private func showWindow() {
        guard let screen = targetScreen() else { return }
        // Compare by frame, not NSScreen identity: the system hands back fresh NSScreen instances for
        // the same display, so identity comparison recreates needlessly (or misses a real change and
        // leaves the notch mispositioned on the wrong screen). A frame change is a real screen change.
        if windowController == nil || windowController?.screen.frame != screen.frame {
            windowController?.window?.orderOut(nil)
            windowController = NotchWindowController(screen: screen, store: store)
        }
        if let window = windowController?.window, !window.isVisible { window.orderFrontRegardless() }
    }

    /// Take the notch off screen (presentation isn't Dynamic Island, or a non-Ask island has it).
    /// Collapse first so it reappears as the pill rather than mid-open, and reset the session edge.
    private func hide() {
        wasAskActive = false
        guard let controller = windowController, controller.window?.isVisible == true else { return }
        controller.viewModel.notchClose()
        controller.window?.orderOut(nil)
    }

    /// The screen the Dynamic Island should appear on. Prefer the display that physically has the
    /// notch / menu-bar inset - that's where the island visually belongs - so it doesn't land on a
    /// notch-less external just because that's where the pointer or key window happens to be. Falls
    /// back to the key window's screen, the pointer's, then main.
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }
}
