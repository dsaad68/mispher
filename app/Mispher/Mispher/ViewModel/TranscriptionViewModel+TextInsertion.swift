import AppKit
import ApplicationServices
import os

/// HUD focus management and writing transcripts back into the user's app. Split out of
/// ``TranscriptionViewModel`` so the main file stays within the length limit. Ask brings Mispher
/// forward (its answer shows in the HUD); Transcription and Rewrite write into the frontmost app,
/// so they only *float* the HUD (never stealing focus) and insert the result via ``SystemTextAccess``.
@MainActor
extension TranscriptionViewModel {
    /// Grab the frontmost app's current selection for a Rewrite session. Returns false (with a
    /// status hint) only if Accessibility isn't granted; otherwise records and resolves the
    /// selection — via the Accessibility API when the app exposes it, else a background ⌘C copy
    /// (which aborts the session with a hint if nothing turns out to be selected). Must run
    /// before Mispher takes focus.
    func beginRewriteCapture() -> Bool {
        guard accessibilityTrusted || AXIsProcessTrusted() else {
            statusMessage = "Grant Accessibility access to rewrite selected text."
            showHudForFeedback()
            return false
        }
        let element = SystemTextAccess.focusedElement()
        rewriteTargetElement = element
        rewriteTargetPID = SystemTextAccess.frontmostTargetPID()
        // Native text views expose the selection here. Apps that don't (browsers, Electron,
        // VS Code) are resolved by a clipboard copy at *finalize* — deferred to then because a
        // synthesized ⌘C now, while the shortcut's ⌥⇧ are physically held, would register as
        // ⌘⌥⇧C and copy nothing.
        rewriteSelection = element.flatMap(SystemTextAccess.selectedTextViaAX) ?? ""
        rewriteResultText = ""
        // Honor the recording-window setting like dictation: in a compact presentation the
        // notch/floating/island overlay shows itself (driven by the recording state), so don't
        // pop the large HUD -- the rewrite is applied silently back into the user's selection.
        if recordingPresentation == .mainWindow { showHudForFeedback() }
        return true
    }

    /// Capture the frontmost app's focused text field for a dictation session so the finished
    /// transcript can be inserted there, and float the HUD **without** activating Mispher — so the
    /// field keeps its caret and the insert (or its ⌘V fallback) lands in it, not in Mispher. Must
    /// run before the HUD shows. Leaves the target nil when Accessibility isn't granted; the insert
    /// then falls back to the clipboard. Mirrors ``beginRewriteCapture()``.
    func beginDictationCapture() {
        // Composer dictation targets the chat field, not the frontmost app: don't capture an external
        // element and don't float the HUD - the transcript streams into the composer and stays put.
        if composerDictationActive {
            dictationTargetElement = nil
            dictationTargetPID = nil
            return
        }
        dictationTargetElement = AXIsProcessTrusted() ? SystemTextAccess.focusedElement() : nil
        dictationTargetPID = AXIsProcessTrusted() ? SystemTextAccess.frontmostTargetPID() : nil
        let target = SystemTextAccess.describe(dictationTargetElement)
        SystemTextAccess.tlog("""
        beginDictationCapture: trusted=\(AXIsProcessTrusted()) \
        targetPID=\(dictationTargetPID.map(String.init) ?? "nil") target=[\(target)]
        """)
        // In a compact presentation the notch/floating overlay shows itself (driven by the
        // recording state), so don't float the large HUD; only the window style does.
        if recordingPresentation == .mainWindow { showHudForFeedback() }
    }

    /// Insert the finished transcript into the field captured when the dictation began, then hide
    /// the HUD so the app the user was typing in returns to the front. Falls back to copying to the
    /// clipboard (keeping the HUD up, with a hint) when the insert can't be performed — Accessibility
    /// not granted, the control is read-only, or dictation started from the HUD itself (no target).
    func finishDictationInsert(_ text: String) {
        // Composer dictation never inserts into another app: the transcript is already mirrored into
        // the chat field. (The finalize path also routes around this for the composer; this is a guard.)
        if composerDictationActive { return }
        let target = dictationTargetElement
        let targetPID = dictationTargetPID
        dictationTargetElement = nil
        dictationTargetPID = nil
        let presentation = String(describing: recordingPresentation)
        SystemTextAccess.tlog("""
        finishDictationInsert: textLen=\(text.count) hasTarget=\(target != nil) \
        targetPID=\(targetPID.map(String.init) ?? "nil") presentation=\(presentation)
        """)
        // Some browser/Electron fields expose no focused AX element at capture time, but the
        // frontmost app PID is still enough for the clipboard-paste fallback. When both are nil,
        // dictation started from Mispher itself, so there is no external field to insert into.
        guard target != nil || targetPID != nil else { return }
        // Leave a trailing space after the inserted transcript so back-to-back dictations don't run
        // their words together and the caret sits ready for the next phrase. Skip it when the text
        // already ends in whitespace.
        let inserted = text.last?.isWhitespace == true ? text : text + " "
        if SystemTextAccess.replaceSelection(in: target, with: inserted, targetPID: targetPID) {
            // In a compact presentation the overlay already hid itself when the session ended;
            // only the window style floated the HUD that now needs hiding.
            if recordingPresentation == .mainWindow { hideHud() }
        } else if !autoCopyOnFinish {
            writeToPasteboard(inserted)
            flashCopied()
            statusMessage = "Copied -- grant Accessibility access to type into apps."
        }
    }

    /// Apply the spoken `instruction` to `selection` and write the result back into `element`,
    /// replacing the selection in the original app. Best-effort: if injection fails the result
    /// is copied to the clipboard; if the model isn't available, nothing changes.
    func runRewrite(
        instruction: String,
        selection providedSelection: String,
        element: AXUIElement?,
        targetPID: pid_t?
    ) async {
        // Hold this on for the whole operation -- it gates the compact overlay (and the
        // main-window "Rewriting…" state). Set before the async selection copy below so the
        // notch/island stays up continuously, rather than flickering off between stop() returning
        // to idle and generation starting. stop() calls this synchronously right after
        // state = .idle (before any await), so the overlay's observer never sees the gap.
        isRewriting = true
        defer { isRewriting = false }

        guard let mlx = mlxModels else {
            statusMessage = selectedModel.readyMessage
            return
        }

        // Resolve the selection. If the Accessibility API didn't provide one at the start
        // (browsers/Electron/VS Code), copy it now — the shortcut's ⌥⇧ are released by finalize,
        // so the synthesized ⌘C is a clean copy. A short settle delay covers a staggered release.
        var selection = providedSelection
        if selection.isEmpty {
            try? await Task.sleep(for: .milliseconds(120))
            selection = await SystemTextAccess.selectedTextViaCopy(targetPID: targetPID) ?? ""
        }
        guard !selection.isEmpty else {
            statusMessage = "Select some text first, then \(rewriteShortcut.display) to rewrite it."
            return
        }

        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "No instruction heard - the selection is unchanged."
            return
        }

        statusMessage = "Rewriting…"

        let result = await mlx.rewrite(
            selection: selection, instruction: trimmed, prompt: rewritePrompt, modelId: rewriteModelId
        )
        // A new session may have started while generating — don't update UI or paste into it.
        guard state == .idle, activeIntent == .rewrite else { return }
        guard let result, !result.isEmpty else {
            statusMessage = "Rewrite unavailable - couldn't run the on-device model."
            return
        }

        rewriteResultText = result
        if SystemTextAccess.replaceSelection(in: element, with: result, targetPID: targetPID) {
            statusMessage = "Rewrote the selection."
        } else {
            writeToPasteboard(result)
            statusMessage = "Couldn't insert - copied the rewrite to the clipboard."
        }
    }

    /// Bring the HUD forward and activate Mispher (used by Ask, whose answer shows in the HUD).
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        let key = NSApp.keyWindow.flatMap { Self.isAuxiliaryPanel($0) ? nil : $0 }
        (key ?? NSApp.windows.first { $0.canBecomeKey && !Self.isAuxiliaryPanel($0) })?
            .makeKeyAndOrderFront(nil)
    }

    /// Open the app's Settings window (e.g. from the notch menu). Mirrors the menu bar item's
    /// "Settings…": surface Mispher (it may be in accessory / menu-bar mode), then post the
    /// notification a SwiftUI view turns into `openWindow(settings)` - only SwiftUI can open the scene.
    func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .mispherShowSettings, object: nil)
    }

    /// True for Mispher's own floating panels (the recording overlay, the Ask notch, the radial mode
    /// picker), which the HUD window-pickers must skip so they don't mistake one for the main window.
    private static func isAuxiliaryPanel(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id == RecordingOverlayController.panelIdentifier || id == NotchWindowController.panelIdentifier
            || id == RadialMenuController.panelIdentifier
    }

    /// Bring the HUD forward for visual feedback **without** activating Mispher — taking focus
    /// would move the frontmost app's selection out from under a Rewrite or dictation.
    func showHudForFeedback() {
        hudWindow()?.orderFrontRegardless()
    }

    /// Hide the HUD window (without quitting) so focus returns to the app underneath, after a hotkey
    /// dictation inserts its transcript. `orderOut` only hides — it doesn't close the window, so it
    /// doesn't trip ``applicationShouldTerminateAfterLastWindowClosed``; the next shortcut re-floats it.
    func hideHud() {
        hudWindow()?.orderOut(nil)
    }

    /// The main HUD window (the first key-capable window that isn't Settings).
    private func hudWindow() -> NSWindow? {
        let settingsID = MispherApp.settingsWindowID
        return NSApp.windows.first {
            $0.identifier?.rawValue != settingsID && !Self.isAuxiliaryPanel($0) && $0.canBecomeKey
        }
            ?? NSApp.windows.first { !Self.isAuxiliaryPanel($0) }
    }

    // MARK: - Clipboard

    /// Copies the current transcript to the pasteboard and flashes feedback.
    func copyTranscript() {
        let text = transcriptForCopy
        guard !text.isEmpty else { return }
        writeToPasteboard(text)
        flashCopied()
    }

    func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func flashCopied() {
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            justCopied = false
        }
    }
}
