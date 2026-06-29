import AppKit
import ApplicationServices
import os

/// Reads the frontmost app's current text selection and writes replacement text back. Backs
/// Rewrite Mode — "edit the highlighted text with your voice". Two strategies, so it works
/// broadly: the Accessibility API first (fast, in-place, native text views), then a clipboard
/// ⌘C/⌘V fallback for apps that don't expose an AX selection (browsers, Electron, editors).
/// Requires Accessibility trust (`AXIsProcessTrusted()`), the same permission the global
/// shortcuts use.
enum SystemTextAccess {
    // TEMP diagnostics. Mirrored to stderr (the same sink FluidAudio's `[INFO]` lines use, so these
    // surface wherever those do -- Xcode console, a terminal, any stderr capture) and to the unified
    // log (filter Console by category "TextInsertion"). NSLog was unreliable here: it routes only to
    // the unified log unless stderr is a tty. Filter either channel by the "MISPHER_TI" tag.
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Mispher", category: "TextInsertion")
    static func tlog(_ message: String) {
        log.notice("MISPHER_TI \(message, privacy: .public)")
        FileHandle.standardError.write(Data("MISPHER_TI \(message)\n".utf8))
    }

    /// A one-line description of an element for logs: role, subrole, owning app + activation
    /// policy, and whether it sits inside a web area. "nil" when there's no element.
    static func describe(_ element: AXUIElement?) -> String {
        guard let element else { return "nil" }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let policy = app.map { String($0.activationPolicy.rawValue) } ?? "?"
        return "role=\(role(of: element) ?? "?") subrole=\(subrole(of: element) ?? "?") "
            + "pid=\(pid) bundle=\(app?.bundleIdentifier ?? "?") policy=\(policy) "
            + "active=\(app?.isActive == true) web=\(isWebContent(element))"
    }

    /// The current frontmost regular app, excluding Mispher itself. Capture this before the HUD
    /// floats so browser/Electron renderer AX elements can still paste through their parent app.
    static func frontmostTargetPID() -> pid_t? {
        usablePID(NSWorkspace.shared.frontmostApplication)
    }

    // MARK: - Capture

    /// The frontmost app's focused element, if any. Used to read/write the selection via the
    /// Accessibility API. Capture this *before* Mispher takes focus.
    static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
            let focused = focusedRef,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        // Safe: the CFGetTypeID guard above proves this is an AXUIElement.
        // swiftlint:disable:next force_cast
        return (focused as! AXUIElement)
    }

    /// The selected text in `element` via the Accessibility API only (no clipboard). Fast;
    /// works in native text views. Returns nil when the element doesn't expose a selection.
    static func selectedTextViaAX(_ element: AXUIElement) -> String? {
        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selectedRef
        ) == .success,
            let selected = selectedRef as? String, !selected.isEmpty {
            return selected
        }
        return selectionFromRange(element)
    }

    /// Copy the current selection by synthesizing ⌘C and reading the pasteboard, restoring the
    /// previous clipboard afterwards. Works in almost any app (browsers, Electron, editors)
    /// that don't expose an Accessibility selection. Returns the copied text, or nil if nothing
    /// was copied (e.g. no selection). Async — the pasteboard updates after the keystroke. The
    /// frontmost app must still be the target (Rewrite never steals focus, so it is).
    @MainActor
    static func selectedTextViaCopy(targetPID: pid_t? = nil) async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let beforeCount = pasteboard.changeCount
        let pid = targetPID ?? frontmostTargetPID()

        // ⌘C follows the real keyboard-focus path. That is the reliable route for Chromium/
        // Electron page fields once the captured app is active again.
        _ = activateApp(pid: pid)
        guard post(keyCode: 0x08, delivery: .focusedHID) else { // kVK_ANSI_C
            return nil
        }

        // Wait for the copy to land (poll the change count up to ~500ms).
        var copied: String?
        for _ in 0 ..< 25 {
            try? await Task.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != beforeCount {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        restore(pasteboard, saved)

        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return copied
    }

    private static func selectionFromRange(_ element: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success,
            AXUIElementCopyAttributeValue(
                element, kAXValueAttribute as CFString, &valueRef
            ) == .success,
            let full = valueRef as? String,
            let rangeValue = rangeRef,
            CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        // Safe: the CFGetTypeID guard above proves this is an AXValue.
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.length > 0 else { return nil }
        let ns = full as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        let selected = ns.substring(with: NSRange(location: range.location, length: range.length))
        return selected.isEmpty ? nil : selected
    }

    // MARK: - Inject

    private enum KeyDelivery {
        case pid(pid_t)
        case focusedHID

        var logDescription: String {
            switch self {
            case .pid(let pid): return "pid:\(pid)"
            case .focusedHID: return "focusedHID"
            }
        }
    }

    /// Replace the current selection with `text`. Tries the Accessibility API first when an
    /// `element` is available (replaces in place); otherwise — or if that fails — falls back to
    /// a clipboard + synthesized ⌘V paste into the app captured when recording began. Returns true
    /// when the paste event was delivered.
    @discardableResult
    static func replaceSelection(in element: AXUIElement?, with text: String, targetPID capturedPID: pid_t? = nil) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        tlog("""
        replaceSelection: trusted=\(AXIsProcessTrusted()) \
        textLen=\(text.count) frontmost=\(frontmost) capturedPID=\(capturedPID.map(String.init) ?? "nil") \
        element=[\(describe(element))]
        """)
        guard AXIsProcessTrusted() else { return false }
        // Web content covers browser page fields and every Electron app (they're Chromium, so their
        // text areas sit under an AXWebArea). Computing this once decides both whether the AX
        // set-value path is worth trying and whether Unicode typing is usable in the fallback below.
        let isWeb = element.map(isWebContent) ?? false
        if let element {
            // Web content reports the AX selection as writable and the set call returns success --
            // yet the text never lands in the field, and because we'd "succeed" we'd never fall
            // through to the ⌘V paste that does work. So skip the AX path for web areas; native
            // controls still take the fast in-place replacement when the attribute is writable.
            if !isWeb {
                var settable: DarwinBoolean = false
                let settableResult = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
                tlog("AX settable: result=\(settableResult.rawValue) ok=\(settable.boolValue)")
                if settableResult == .success, settable.boolValue {
                    let setResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
                    tlog("AX set: result=\(setResult.rawValue)")
                    if setResult == .success {
                        tlog("replaceSelection -> AX set")
                        return true
                    }
                }
            } else {
                tlog("replaceSelection: web content, skipping AX set")
            }
            // Bring the element's app frontmost so the insert lands in it, not whatever app is
            // frontmost after generation.
            activateTarget(element: element, fallbackPID: capturedPID)
        }
        let pid = targetPid(for: element, capturedPID: capturedPID)
        let delivery: KeyDelivery
        if isWeb || regularAppPID(for: element) == nil {
            _ = activateApp(pid: pid)
            delivery = .focusedHID
        } else if let pid {
            delivery = .pid(pid)
        } else {
            delivery = .focusedHID
        }
        tlog("replaceSelection: targetPid=\(pid.map(String.init) ?? "nil") delivery=\(delivery.logDescription)")
        // Everything that isn't a native AX-settable field takes a clipboard paste. Browser and
        // Electron fields need the real focused-keyboard route; posting only to Chrome's app PID can
        // be accepted by the system while never reaching the renderer's focused text control.
        let pasted = pasteViaClipboard(text, delivery: delivery)
        tlog("replaceSelection -> clipboard paste=\(pasted)")
        return pasted
    }

    /// The app process to use for activation or app-directed key events. The PID captured at
    /// shortcut start wins because the active app may be Mispher by the time generation finishes.
    private static func targetPid(for element: AXUIElement?, capturedPID: pid_t?) -> pid_t? {
        if runningTargetApp(capturedPID) != nil { return capturedPID }
        if let elementPID = regularAppPID(for: element) { return elementPID }
        return frontmostTargetPID()
    }

    /// Whether `element` lives inside a web view — i.e. has an `AXWebArea` ancestor. Browser page
    /// fields and Electron content land here; native AppKit controls (Chrome's omnibox, Notes) do
    /// not. The walk stops at the window so it stays bounded.
    private static func isWebContent(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0 ..< 50 {
            guard let element = current else { return false }
            switch role(of: element) {
            case "AXWebArea": return true
            case "AXWindow", "AXApplication", "AXSheet": return false
            default: break
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            // Safe: the CFGetTypeID guard above proves this is an AXUIElement.
            // swiftlint:disable:next force_cast
            current = (parent as! AXUIElement)
        }
        return false
    }

    /// The Accessibility role of `element` (e.g. `AXTextField`, `AXWebArea`), if it exposes one.
    private static func role(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// The Accessibility subrole of `element`, if any. Diagnostics only.
    private static func subrole(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Bring the target app to the front before a focused-keyboard paste. Never activates a web
    /// content child process; when the AX element belongs to one, use the captured parent app PID.
    private static func activateTarget(element: AXUIElement?, fallbackPID: pid_t?) {
        if let elementPID = regularAppPID(for: element) {
            _ = activateApp(pid: elementPID)
        } else {
            _ = activateApp(pid: fallbackPID)
        }
    }

    private static func regularAppPID(for element: AXUIElement?) -> pid_t? {
        guard let element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              runningTargetApp(pid) != nil else { return nil }
        return pid
    }

    private static func runningTargetApp(_ pid: pid_t?) -> NSRunningApplication? {
        guard let pid, pid != NSRunningApplication.current.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else { return nil }
        return app
    }

    private static func usablePID(_ app: NSRunningApplication?) -> pid_t? {
        guard let app, app.processIdentifier != NSRunningApplication.current.processIdentifier,
              app.activationPolicy == .regular else { return nil }
        return app.processIdentifier
    }

    @discardableResult
    private static func activateApp(pid: pid_t?) -> Bool {
        guard let app = runningTargetApp(pid) else {
            tlog("activateApp: skipped (no regular target app)")
            return false
        }
        guard !app.isActive else {
            tlog("activateApp: skipped (already active \(app.bundleIdentifier ?? "?"))")
            return false
        }
        tlog("activateApp: activating \(app.bundleIdentifier ?? "?")")
        let activated = app.activate()
        if activated { Thread.sleep(forTimeInterval: 0.08) }
        return activated
    }

    /// Save the clipboard, put `text` on it, synthesize ⌘V, then restore the clipboard.
    private static func pasteViaClipboard(_ text: String, delivery: KeyDelivery) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let writtenChange = pasteboard.changeCount

        guard post(keyCode: 0x09, delivery: delivery) else { // kVK_ANSI_V
            restore(pasteboard, saved) // couldn't synthesize ⌘V — don't leave the user's clipboard replaced
            return false
        }

        // Restore the previous clipboard once the paste has landed. Chromium/Electron apps
        // (Chrome, VS Code, Slack) read the pasteboard asynchronously over IPC, well after the
        // ⌘V keystroke — restoring too soon makes them paste the *previous* clipboard, or
        // nothing at all. Wait long enough to clear that window, and skip the restore if
        // something else has claimed the clipboard since, so we never clobber a fresh copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == writtenChange else { return }
            restore(pasteboard, saved)
        }
        return true
    }

    /// A Sendable snapshot of the *entire* pasteboard — every item's types and data, not just
    /// the plain string — so images, files, and rich text survive a synthetic copy/paste.
    /// (Promised/lazy data that isn't materialized yet can't be captured and is skipped.)
    private static func snapshot(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var map: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { map[type.rawValue] = data }
            }
            return map
        }
    }

    /// Restore a pasteboard snapshot taken by ``snapshot(_:)``.
    private static func restore(_ pasteboard: NSPasteboard, _ snapshot: [[String: Data]]) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        pasteboard.writeObjects(snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type)) }
            return item
        })
    }

    /// Synthesize a ⌘+`keyCode` keystroke either to a specific app event queue or through the
    /// focused HID route. The latter is required for Chromium/Electron renderer-backed fields.
    private static func post(keyCode: CGKeyCode, delivery: KeyDelivery) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        switch delivery {
        case .pid(let pid):
            keyDown.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.01) // let the key-down register before releasing
            keyUp.postToPid(pid)
        case .focusedHID:
            keyDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
            keyUp.post(tap: .cghidEventTap)
        }
        return true
    }
}
