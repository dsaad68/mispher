import AppKit
import SwiftUI

/// True backdrop blur of whatever is *behind the window* (the desktop / other
/// apps), via `NSVisualEffectView` with behind-window blending — the basis for
/// the frosted-glass shell. SwiftUI's `Material` only blurs in-window content,
/// so it can't produce this look on its own.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Reaches up to the hosting `NSWindow` and turns it into a borderless,
/// transparent, shadowed shell so the rounded glass panel appears to float over
/// the desktop. The window stays rectangular but its corners are transparent —
/// macOS derives the drop shadow from the visible (rounded) content silhouette.
struct GlassWindowConfigurator: NSViewRepresentable {
    /// When true the window floats above other apps' windows.
    var alwaysOnTop: Bool = false

    func makeNSView(context: Context) -> NSView {
        let proxy = NSView()
        let onTop = alwaysOnTop
        DispatchQueue.main.async {
            guard let window = proxy.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.isMovableByWindowBackground = false
            window.level = onTop ? .floating : .normal
        }
        return proxy
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let onTop = alwaysOnTop
        DispatchQueue.main.async {
            nsView.window?.level = onTop ? .floating : .normal
        }
    }
}

/// Configures the Settings window: a *native* opaque window (so the OS draws one clean
/// rounded border + shadow — no transparent gap or double edge), with a transparent,
/// full-size-content titlebar so the dark material fills edge to edge under the traffic
/// lights. Its level tracks the HUD's so Settings opens above a floating HUD.
struct SettingsWindowConfigurator: NSViewRepresentable {
    var alwaysOnTop: Bool = false
    /// When set, pins the window to this fixed, non-resizable content size (the sidebar + title stay
    /// put and long tabs scroll), instead of letting it shrink-wrap and resize per tab.
    var lockedContentSize: CGSize?

    func makeNSView(context: Context) -> NSView {
        let proxy = NSView()
        let onTop = alwaysOnTop
        let locked = lockedContentSize
        DispatchQueue.main.async {
            guard let window = proxy.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.isMovableByWindowBackground = false
            window.isOpaque = true
            window.backgroundColor = NSColor(Palette.bgDeep)
            if let locked {
                window.styleMask.remove(.resizable) // fixed size; content scrolls instead
                window.isRestorable = false
                window.setFrameAutosaveName("") // don't restore a stale frame from a prior run
                window.setContentSize(locked)
                window.center()
            }
            window.level = onTop ? .floating : .normal
            window.surfaceAboveOtherApps() // come above other apps when opened from the menu bar
        }
        return proxy
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let onTop = alwaysOnTop
        DispatchQueue.main.async {
            nsView.window?.level = onTop ? .floating : .normal
        }
    }
}

extension NSWindow {
    /// Surface this window above every other app's windows when it's shown from the menu bar (Settings
    /// / onboarding). `makeKeyAndOrderFront` only orders within our own app, so `orderFrontRegardless`
    /// is what forces it past other apps' normal-level windows. The app may have just flipped from
    /// `.accessory` to `.regular`, where the first activate is routinely dropped, so we re-assert once
    /// on the next runloop turn.
    func surfaceAboveOtherApps() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.makeKeyAndOrderFront(nil)
            self.orderFrontRegardless()
        }
    }
}
