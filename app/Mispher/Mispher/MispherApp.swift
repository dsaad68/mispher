import AppKit
import DeepAgents
import DeepAgentsMLX
import SwiftUI

/// App lifecycle glue. On launch it activates as a regular GUI app (needed when run as a bare
/// SwiftPM executable, which has no bundle identity). When "Close to menu bar" is on it keeps
/// Mispher alive by *hiding* the main window on close instead of letting it close -- so the app
/// doesn't quit, the window's state survives, and it can be brought right back (closing a SwiftUI
/// singleton `Window` and reopening it via `openWindow` is unreliable). Optionally it also drops
/// the Dock icon so Mispher runs as a menu-bar-only app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// Setting key, read straight from `UserDefaults` since the delegate has no view model.
    private static let closeToMenuBarKey = "mispher.closeToMenuBar"
    /// Launch hidden in the menu bar (HUD stays closed until "Open Mispher").
    private static let startInMenuBarModeKey = "mispher.startInMenuBarMode"

    /// One-shot guard so the launch presentation (hiding the HUD for menu-bar start) is applied
    /// only when the window first appears, not on later re-binds.
    private var didApplyLaunchMode = false
    /// True while "Start in the menu bar" is keeping the freshly-launched HUD hidden. SwiftUI can
    /// (re-)present the window on a later runloop turn, so this gates a `didBecomeKey` observer that
    /// re-hides it until the user opens it via `showMainWindow`.
    private var keepMainWindowHidden = false

    /// The main HUD window, captured when it first appears so the menu-bar / Dock paths can bring
    /// it straight back. Weak: the window owns itself.
    private(set) weak var mainWindow: NSWindow?
    /// Retains the close interceptor we install (the window holds its delegate weakly).
    private var mainWindowCloser: MainWindowCloseDelegate?
    /// The menu bar item, present only while "Close to menu bar" is on. Managed here in AppKit
    /// rather than via SwiftUI's `MenuBarExtra`, whose `isInserted:` binding does not reliably
    /// react to the setting changing (so the icon never appeared).
    private var statusItem: NSStatusItem?
    /// The dropdown shown from the menu bar item -- a custom SwiftUI popover, not a stock `NSMenu`.
    private var popover: NSPopover?
    /// The shared view model, handed over from ``MispherApp`` so the menu bar dropdown can offer the
    /// translation-language quick picker. Held weakly: the App owns it for the process lifetime.
    weak var viewModel: TranscriptionViewModel?
    /// The radial mode picker overlay, handed over from the scene so ``startHotKeys(for:)`` can drive
    /// it from the engine's radial callbacks. Held weakly: the scene owns it via `@State`.
    weak var radialMenu: RadialMenuController?
    /// When the popover last closed, so the status-item click that dismissed a transient popover
    /// doesn't immediately reopen it.
    private var popoverClosedAt = Date.distantPast
    /// Watches for clicks in other apps while the dropdown is open and closes it -- a `.transient`
    /// status-item popover doesn't reliably auto-dismiss for an accessory (menu-bar) app, since the
    /// outside mouse events aren't delivered to it.
    private var popoverMonitor: Any?

    /// The global keyboard shortcut engine (Transcription / Ask / Rewrite / Translate / Stop).
    /// Owned here -- not on a view -- so it installs at launch and keeps working regardless of
    /// whether the HUD window is open: the system-wide `CGEventTap` lives on the main run loop, not
    /// a window. Started once via ``startHotKeys(for:)``.
    private let hotKeyTap = HotKeyTap()
    /// One-shot guard so the shortcut engine starts a single time for the process.
    private var didStartHotKeys = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Mispher is a menu-bar app: it always launches into the menu bar (chat window hidden), stays
        // alive there when the window closes, and shows the Dock icon only while the window is open.
        // These three flags drive the (still-present) menu-bar machinery below and elsewhere in this
        // file; force them on so the behavior is unconditional now that the Settings toggles are gone.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.startInMenuBarModeKey)
        defaults.set(true, forKey: Self.closeToMenuBarKey)
        defaults.set(true, forKey: "mispher.hideDockInMenuBarMode")

        // Menu-bar-only at launch: no Dock icon and no activation; the freshly-created chat window is
        // hidden by `bindMainWindow` until the user picks "Open Chat" from the menu bar.
        NSApp.setActivationPolicy(.accessory)
        syncStatusItem() // install the menu bar item (the only way to open the window at launch)
        // Re-check the Dock icon after any window closes: closing Settings after the
        // main window was already hidden to the menu bar should still drop the Dock icon.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil
        )
        // Promote the shortcut engine from the focus-only fallback to the system-wide tap whenever
        // the app gains focus. `AXIsProcessTrusted()` can read false for longer than the cold-launch
        // poll covers; this is the durable recovery so hotkeys come alive without having to reopen
        // the HUD.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil
        )
        // The onboarding wizard finishing returns the app to the menu bar (drops the Dock icon, keeps
        // the chat window hidden) - the user lands back in the menu bar, not on the chat.
        NotificationCenter.default.addObserver(
            self, selector: #selector(hideToMenuBarFromNotification),
            name: .mispherHideToMenuBar, object: nil
        )
    }

    @objc private func hideToMenuBarFromNotification(_ note: Notification) { hideToMenuBar() }

    @objc private func appDidBecomeActive(_ note: Notification) {
        guard didStartHotKeys else { return } // don't install ahead of `startHotKeys` (avoids a double tap)
        viewModel?.refreshAccessibilityTrust()
        viewModel?.refreshMicPermission()
        hotKeyTap.refresh()
    }

    /// Drop the Dock icon once no ordinary window is left, while in menu-bar mode with "hide Dock"
    /// on. The close interceptor handles the main window; this covers auxiliary windows closing
    /// afterwards (there's otherwise no hook for that).
    @objc private func windowWillClose(_ note: Notification) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "mispher.closeToMenuBar"),
              defaults.bool(forKey: "mispher.hideDockInMenuBarMode") else { return }
        // Defer a tick so the closing window is gone when we count what's left.
        Task { @MainActor in
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Belt-and-suspenders: if the main window is ever closed without the interceptor (e.g. before
    /// it's installed), still keep the app alive in menu-bar mode.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: Self.closeToMenuBarKey)
    }

    /// Clicking the Dock icon (when it's kept) with no open windows re-shows the HUD.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    /// Stop any `llama-server` processes we launched so they don't outlive the app.
    /// Externally-started servers aren't tracked, so they're left running.
    func applicationWillTerminate(_ notification: Notification) {
        ServerPidRegistry.shared.terminateAll()
    }

    /// Capture the main HUD window and install the close interceptor. Idempotent.
    func bindMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(MispherApp.mainWindowID)
        let closer = MainWindowCloseDelegate()
        closer.forwardee = window.delegate
        window.delegate = closer
        mainWindowCloser = closer
        // "Start in the menu bar": keep the HUD hidden on launch (applied once) until the user
        // opens it from the menu bar; `showMainWindow` brings it back.
        if !didApplyLaunchMode {
            didApplyLaunchMode = true
            if UserDefaults.standard.bool(forKey: Self.startInMenuBarModeKey) {
                // SwiftUI flips the app back to `.regular` (Dock icon + activation) when the first
                // Window scene appears, overriding the `.accessory` set in
                // `applicationDidFinishLaunching` (which also isn't reliable with this app's custom
                // `@main`). Re-apply it here - after the window exists - so "Start in the menu bar"
                // actually launches Dock-less, and make sure the menu bar item is there to reopen it.
                NSApp.setActivationPolicy(.accessory)
                syncStatusItem()
                // Hide the HUD. SwiftUI presents this Window right after this resolve and can
                // re-order it front on a later runloop turn, racing a lone `orderOut` (which is why
                // the HUD used to show through). Belt and suspenders: drop it out of state
                // restoration; set alpha to 0 so any present that slips through is invisible (no
                // flash); order it out now and again next runloop; and re-hide on every `didBecomeKey`
                // until the user opens it (`showMainWindow` clears `keepMainWindowHidden`).
                keepMainWindowHidden = true
                window.isRestorable = false
                window.alphaValue = 0
                window.orderOut(nil)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(mainWindowDidBecomeKey),
                    name: NSWindow.didBecomeKeyNotification, object: window
                )
                Task { @MainActor in if self.keepMainWindowHidden { window.orderOut(nil) } }
            }
        }
    }

    /// While "Start in the menu bar" is holding the HUD closed, undo any SwiftUI present.
    @objc private func mainWindowDidBecomeKey(_ note: Notification) {
        guard keepMainWindowHidden else { return }
        (note.object as? NSWindow)?.orderOut(nil)
    }

    /// Bring the main HUD back: stop holding it hidden, restore a regular (Dock-visible) app,
    /// re-show the window (restoring alpha if it launched hidden), and activate.
    func showMainWindow() {
        keepMainWindowHidden = false
        mainWindow?.alphaValue = 1
        bringToFront(mainWindow)
    }

    /// Force the app and a window to the foreground after an `.accessory` -> `.regular` flip. The
    /// first activate right after the policy change is routinely dropped (the app isn't yet
    /// foreground-eligible on that runloop turn), leaving the window behind other apps - so re-assert
    /// once on the next turn. Used to surface both the chat window and the onboarding wizard.
    func bringToFront(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Drop back to the menu bar without surfacing the chat: keep the main window held hidden, order
    /// it out, remove the Dock icon, and make sure the menu bar item is present. Used when the
    /// onboarding wizard finishes (the app was activated to `.regular` to show the wizard), so the
    /// user returns to the menu bar instead of the chat window. "Open Chat" reopens it via
    /// ``showMainWindow``.
    func hideToMenuBar() {
        keepMainWindowHidden = true
        mainWindow?.alphaValue = 0
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        syncStatusItem()
    }

    // MARK: - Global shortcuts

    /// Install the global shortcut engine, wiring its phases to the view model. Idempotent: it runs
    /// once for the process. Called from the HUD scene's `onAppear` (where the view model is set),
    /// which fires at launch in both window modes, so shortcuts are live from launch.
    func startHotKeys(for vm: TranscriptionViewModel) {
        guard !didStartHotKeys else { return }
        didStartHotKeys = true
        hotKeyTap.start(
            config: vm.shortcutConfig,
            onIntent: { intent, phase in
                switch phase {
                case .press: vm.shortcutPressed(intent)
                case .release: vm.shortcutReleased(intent)
                case .tap: vm.shortcutTapped(intent)
                case .cancel: vm.shortcutCancelled(intent)
                }
            },
            onStop: { vm.stopPressed() },
            isSessionActive: { vm.isSessionActive },
            onRadialOpen: { [weak self] in self?.radialMenu?.open() },
            onRadialClose: { [weak self] in self?.radialMenu?.close() },
            onRadialCancel: { [weak self] in self?.radialMenu?.cancel() },
            onRadialArrow: { [weak self] direction in self?.radialMenu?.handleArrow(direction) }
        )
    }

    /// Push a new shortcut binding set to the engine (after the user edits shortcuts in Settings).
    func updateHotKeyConfig(_ config: HotKeyTap.Config) { hotKeyTap.updateConfig(config) }

    /// Stand the engine down (or back up) while a Settings shortcut recorder captures keys.
    func setHotKeysEnabled(_ enabled: Bool) { hotKeyTap.setEnabled(enabled) }

    /// Re-evaluate Accessibility trust and switch between the system-wide tap and the local
    /// fallback (called when the user grants/revokes access).
    func refreshHotKeys() { hotKeyTap.refresh() }

    // MARK: - Menu bar item

    /// Add or remove the menu bar item to match the "Close to menu bar" setting. Called from the
    /// SwiftUI scenes (on launch via `onAppear`, and on `onChange` of the setting) so it doesn't
    /// depend on the app-delegate launch callback firing -- which isn't reliable with this app's
    /// custom `@main` bootstrap.
    func syncStatusItem() {
        let defaults = UserDefaults.standard
        // The menu bar item is needed for both "close to menu bar" and "start in the menu bar"
        // (the latter is the only way to open the HUD when it launches hidden).
        if defaults.bool(forKey: Self.closeToMenuBarKey) || defaults.bool(forKey: Self.startInMenuBarModeKey) {
            installStatusItem()
        } else {
            removeStatusItem()
            NSApp.setActivationPolicy(.regular) // restore the Dock icon if it had been hidden
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Mispher") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "Mispher" // fallback so the item is never invisible
        }
        item.button?.action = #selector(toggleMenu)
        item.button?.target = self
        statusItem = item
    }

    private func removeStatusItem() {
        popover?.performClose(nil)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    /// Toggle the custom glass dropdown below the menu bar item.
    @objc private func toggleMenu() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        // The same click that dismissed a transient popover also fires this action; ignore it so
        // the popover doesn't immediately reopen.
        guard Date().timeIntervalSince(popoverClosedAt) > 0.2 else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        let menu = MenuBarMenu(
            onOpen: { [weak self] in
                self?.popover?.performClose(nil)
                self?.showMainWindow()
            },
            onSettings: { [weak self] in
                self?.popover?.performClose(nil)
                self?.openSettings()
            },
            onWelcome: { [weak self] in
                self?.popover?.performClose(nil)
                self?.openOnboarding()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        // Inject the view model so the dropdown's translation-language picker is live; the rows that
        // don't need it still work if it's somehow absent.
        let rootView = viewModel.map { AnyView(menu.environment($0)) } ?? AnyView(menu)
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Backstop for `.transient` not firing in accessory mode: close on a click in any other app.
        // (Clicks inside the popover or on the status button are local events, so they don't trip it.)
        popoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover?.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        popover = nil
        if let popoverMonitor { NSEvent.removeMonitor(popoverMonitor) }
        popoverMonitor = nil
    }

    private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Only SwiftUI can open the Settings window scene; a view bridges this to `openWindow`.
        NotificationCenter.default.post(name: .mispherShowSettings, object: nil)
    }

    private func openOnboarding() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Only SwiftUI can open the Welcome window scene; a view bridges this to `openWindow`.
        NotificationCenter.default.post(name: .mispherShowOnboarding, object: nil)
    }
}

/// The custom dropdown shown from the menu bar item, in the app's glass language -- a small header
/// plus rows that highlight on hover -- instead of a stock `NSMenu`.
private struct MenuBarMenu: View {
    let onOpen: () -> Void
    let onSettings: () -> Void
    let onWelcome: () -> Void
    let onQuit: () -> Void
    /// Optional: present when ``MispherApp`` injected it, so the language picker can read/set the
    /// target language. The action rows work without it.
    @Environment(TranscriptionViewModel.self) private var vm: TranscriptionViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text("Mispher")
                    .font(.title(14, weight: .semibold))
                    .foregroundStyle(Palette.fg1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 5)

            if let vm {
                MenuBarMicrophonePicker(vm: vm)
                Hairline().padding(.horizontal, 8).padding(.vertical, 4)
                MenuBarTranslatePicker(vm: vm)
                Hairline().padding(.horizontal, 8).padding(.vertical, 4)
            }

            MenuBarRow(title: "Open Chat", systemImage: "bubble.left.and.bubble.right", action: onOpen)
            MenuBarRow(title: "Settings…", systemImage: "gearshape", action: onSettings)
            MenuBarRow(title: "Run setup again", systemImage: "sparkles", action: onWelcome)
            Hairline().padding(.horizontal, 8).padding(.vertical, 4)
            MenuBarRow(
                title: "Quit Mispher", systemImage: "power",
                tint: Palette.recRed, hoverText: .white, action: onQuit
            )
        }
        .padding(6)
        .frame(width: 216)
        .background(Palette.bgDeep)
        .preferredColorScheme(.dark)
        .onAppear { vm?.refreshInputDevices() }
    }
}

/// The menu bar's "Translate to" control: a single row showing the current target language by full
/// name, which expands inline to a checkable list of the languages the active model supports - so the
/// language can be switched from the menu bar without opening Settings, while staying compact at rest.
private struct MenuBarTranslatePicker: View {
    let vm: TranscriptionViewModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                // No SwiftUI animation here: the menu lives in an NSPopover sized to its content
                // (`preferredContentSize`), so animating the height makes the popover re-measure and
                // resize every frame - which reads as flashing / jitter. Toggle instantly so the
                // popover resizes once, cleanly.
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Translate to")
                        .font(.sans(12.5, weight: .medium))
                        .foregroundStyle(Palette.fg)
                    Spacer(minLength: 8)
                    Text(vm.translationTargetLanguage.displayName)
                        .font(.sans(11.5, weight: .medium))
                        .foregroundStyle(Palette.accent)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.fg3)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(vm.translationLanguages) { language in
                    MenuBarLanguageRow(
                        language: language,
                        isSelected: vm.translationTargetLanguage == language
                    ) { vm.translationTargetLanguage = language }
                }
            }
        }
    }
}

/// One language row in the expanded menu bar picker: a checkmark slot, the full language name, and a
/// soft accent hover wash.
private struct MenuBarLanguageRow: View {
    let language: TranslationLanguage
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 13)
                    .opacity(isSelected ? 1 : 0)
                Text(language.displayName)
                    .font(.sans(12, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 8)
            }
            .foregroundStyle(isSelected ? Palette.accent : (hovering ? Palette.fg : Palette.fg1))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Palette.accent.opacity(0.14) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The menu bar's "Microphone" control: a single row showing the current input device, which
/// expands inline to a checkable list of available devices (plus System Default) - so the mic can
/// be switched from the menu bar without opening Settings, mirroring the Translate picker.
private struct MenuBarMicrophonePicker: View {
    let vm: TranscriptionViewModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                // No SwiftUI animation: the menu lives in an NSPopover sized to its content, so
                // animating the height makes it re-measure every frame (jitter). Toggle instantly.
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Microphone")
                        .font(.sans(12.5, weight: .medium))
                        .foregroundStyle(Palette.fg)
                    Spacer(minLength: 8)
                    Text(vm.selectedInputDeviceLabel)
                        .font(.sans(11.5, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.fg3)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                MenuBarMicrophoneRow(name: "System Default", isSelected: vm.selectedInputDeviceUID.isEmpty) {
                    vm.selectedInputDeviceUID = ""
                }
                ForEach(vm.availableInputDevices) { device in
                    MenuBarMicrophoneRow(name: device.name, isSelected: vm.selectedInputDeviceUID == device.uid) {
                        vm.selectedInputDeviceUID = device.uid
                    }
                }
            }
        }
    }
}

/// One device row in the expanded menu bar microphone picker: a checkmark slot, the device name,
/// and a soft accent hover wash.
private struct MenuBarMicrophoneRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 13)
                    .opacity(isSelected ? 1 : 0)
                Text(name)
                    .font(.sans(12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .foregroundStyle(isSelected ? Palette.accent : (hovering ? Palette.fg : Palette.fg1))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Palette.accent.opacity(0.14) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A row in the menu bar dropdown that fills with an accent (or red) highlight on hover.
private struct MenuBarRow: View {
    let title: String
    let systemImage: String
    var tint: Color = Palette.accent
    var hoverText: Color = Palette.bgDeep
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.sans(12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? hoverText : Palette.fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? tint : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Intercepts the main window's close so "Close to menu bar" can hide it (keeping the app and its
/// state alive) instead of letting it close (which would quit the app or tear down the singleton
/// window). Every other delegate message is forwarded to SwiftUI's own window delegate so the
/// window keeps behaving normally.
final class MainWindowCloseDelegate: NSObject, NSWindowDelegate {
    /// SwiftUI's original window delegate, retained so it isn't deallocated when we take over the
    /// (weak) `window.delegate`, and forwarded to for everything except `windowShouldClose`.
    /// Only ever touched on the main thread.
    nonisolated(unsafe) var forwardee: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            let defaults = UserDefaults.standard
            guard defaults.bool(forKey: "mispher.closeToMenuBar") else {
                return forwardee?.windowShouldClose?(sender) ?? true
            }
            // Hide instead of close: the app stays alive and the window can be brought right back.
            sender.orderOut(nil)
            if defaults.bool(forKey: "mispher.hideDockInMenuBarMode"),
               !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.setActivationPolicy(.accessory)
            }
            return false
        }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        (forwardee?.responds(to: aSelector) == true) ? forwardee : super.forwardingTarget(for: aSelector)
    }
}

/// Hands the hosting `NSWindow` back once the SwiftUI view is installed in it, so the App can
/// capture the main window and intercept its close. Uses `viewDidMoveToWindow` -- no polling.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { WindowReaderView(onResolve: onResolve) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowReaderView: NSView {
    private let onResolve: @MainActor (NSWindow) -> Void

    init(onResolve: @escaping @MainActor (NSWindow) -> Void) {
        self.onResolve = onResolve
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onResolve(window) }
    }
}

extension Notification.Name {
    /// Posted by the menu bar item's "Settings…" action; a SwiftUI view opens the Settings window.
    static let mispherShowSettings = Notification.Name("mispher.showSettings")
    /// Posted by the menu bar item's "Run setup again" action; a SwiftUI view opens the Welcome window.
    static let mispherShowOnboarding = Notification.Name("mispher.showOnboarding")
    /// Posted when the onboarding wizard finishes; the app delegate drops back to the menu bar (Dock
    /// icon gone, chat window kept hidden) rather than surfacing the chat. The chat window stays open
    /// from the menu bar's "Open Chat".
    static let mispherHideToMenuBar = Notification.Name("mispher.hideToMenuBar")
}

struct MispherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = TranscriptionViewModel()
    @State private var mlxModels = MlxModelManager()
    @State private var recordingOverlay = RecordingOverlayController()
    @State private var askNotch = AskNotchController()
    @State private var radialMenu = RadialMenuController()

    init() {
        // Register the bundled custom typefaces before any view renders so `Font.custom(...)`
        // resolves them on first use.
        AppFonts.register()
    }

    var body: some Scene {
        // A single HUD window (not a WindowGroup) so closing + reopening from the menu bar reuses
        // one instance instead of spawning duplicates. The view model lives on the App, so its
        // state survives the window being closed to the menu bar and reopened.
        Window("Mispher", id: Self.mainWindowID) {
            ChatWindowView()
                .environment(viewModel)
                .environment(mlxModels)
                .frame(minWidth: 440, minHeight: 500)
                .background(WindowAccessor { appDelegate.bindMainWindow($0) })
                .onAppear {
                    viewModel.mlxModels = mlxModels
                    // The window is chat-only: enter chat mode now that the model manager is wired, so
                    // its `didSet` warms the Ask DeepAgent (and notch/overlay readers stay consistent).
                    // Must run *after* `mlxModels` is set, or the warm no-ops and the chat stays stuck
                    // on "Loading…".
                    viewModel.chatMode = true
                    appDelegate.viewModel = viewModel // lets the menu bar dropdown reach it
                    recordingOverlay.attach(viewModel, mlx: mlxModels)
                    radialMenu.attach(viewModel)
                    appDelegate.radialMenu = radialMenu // lets the engine drive the wheel
                    askNotch.attach(viewModel, mlx: mlxModels) // the Ask DeepAgent notch (Dynamic Island)
                    appDelegate.syncStatusItem() // install the menu bar item at launch if enabled
                    appDelegate.startHotKeys(for: viewModel) // global shortcut engine (once per process)
                    // Connect configured MCP servers now so their tools are warm before the first
                    // agent run (OAuth servers not yet signed in are skipped - no browser at launch).
                    Task { await mlxModels.warmMCP() }
                    // Load the saved conversation list from `~/.mispher` so the notch shows past
                    // conversations as soon as it opens.
                    Task { await mlxModels.refreshConversations() }
                }
                .onChange(of: viewModel.shortcutConfig) { _, config in
                    if !viewModel.isCapturingShortcut { appDelegate.updateHotKeyConfig(config) }
                }
                .onChange(of: viewModel.isCapturingShortcut) { _, capturing in
                    appDelegate.setHotKeysEnabled(!capturing) // stand down while recording a shortcut
                }
                .onChange(of: viewModel.accessibilityTrusted) { _, _ in appDelegate.refreshHotKeys() }
        }
        .windowStyle(.hiddenTitleBar)
        // Keep a stable, user-resizable window; the transcript scrolls inside it
        // instead of growing the window as text streams in.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 480, height: 580)

        // Settings as its own window (opened from the HUD's gear) so it has native
        // traffic-light controls and is non-modal — the HUD stays usable behind it.
        // `hiddenTitleBar` keeps the glass look; the window sizes to the view.
        Window("Settings", id: Self.settingsWindowID) {
            SettingsView()
                .environment(viewModel)
                .environment(mlxModels)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 740)
        .defaultPosition(.center)

        // The first-run welcome / setup wizard. Auto-opens once on first launch (see
        // ``ChatWindowView``) and is re-runnable from the menu bar's "Run setup again".
        Window("Welcome", id: Self.onboardingWindowID) {
            OnboardingView()
                .environment(viewModel)
                .environment(mlxModels)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 580, height: 750)
        .defaultPosition(.center)
    }

    /// Scene id for the main HUD window, opened via `openWindow(id:)`.
    static let mainWindowID = "main"

    /// Scene id for the Settings window, opened via `openWindow(id:)`.
    static let settingsWindowID = "settings"

    /// Scene id for the Welcome / onboarding window, opened via `openWindow(id:)`.
    static let onboardingWindowID = "welcome"
}

/// Entry point. Normally launches the GUI; `MISPHER_SELFTEST=audio|parakeet`
/// runs a headless smoke test instead.
///
/// `main()` is intentionally synchronous — the GUI path must hand the main
/// thread to `App.main()` the normal way (an async main breaks the SwiftUI app
/// lifecycle and the window never appears). The self-test paths spawn a Task and
/// drive the main run loop so the main-actor work can run, then `exit(0)`.
@main
enum MispherMain {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        switch env["MISPHER_SELFTEST"] {
        case "audio":
            Task { await AudioSelfTest.run(); exit(0) }
            RunLoop.main.run()
        case "parakeet":
            let file = env["MISPHER_SELFTEST_FILE"] ?? ""
            Task { await AudioSelfTest.runParakeet(path: file); exit(0) }
            RunLoop.main.run()
        default:
            MispherApp.main()
        }
    }
}
