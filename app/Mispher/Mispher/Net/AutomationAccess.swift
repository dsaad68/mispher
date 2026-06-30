import AppKit
import CoreServices
import Foundation

/// macOS Automation (Apple Events) permission, by target bundle id. The Ask agent ultimately drives
/// Apple Notes through `osascript` (see `DeepAgentsMacTools/AppleNotesMiddleware`), which trips this
/// TCC prompt the first time. Requesting it up front in onboarding means the user grants it once,
/// while the app is frontmost, instead of being surprised mid-conversation.
enum AutomationAccess {
    /// Bundle id of Apple Notes, the one Automation target Mispher uses today.
    static let appleNotesBundleID = "com.apple.Notes"

    /// Whether the app is allowed to automate `bundleID`. With `askUserIfNeeded` the system surfaces
    /// its Automation prompt the first time. Two non-obvious requirements are handled here:
    ///  - the determination only works against a *running* target (else `procNotFound`), so we
    ///    launch it hidden in the background first when it isn't already up; and
    ///  - `AEDeterminePermissionToAutomateTarget` *blocks* the calling thread until the user answers
    ///    the consent dialog, so it must run off the main thread or the dialog never appears.
    /// Best-effort: if the target can't be found / launched this returns false.
    @discardableResult
    static func requestPermission(forBundleID bundleID: String, askUserIfNeeded: Bool = true) async -> Bool {
        let launched = await launchIfNeeded(bundleID: bundleID)
        // Run the (blocking) determination off the main thread so the consent dialog can present.
        let granted = await Task.detached {
            determinePermission(forBundleID: bundleID, askUserIfNeeded: askUserIfNeeded)
        }.value
        // If we opened the app only to ask, close it again so we don't leave a window the user
        // never asked for. (No-op when it was already running: `launched` is nil.)
        launched?.terminate()
        return granted
    }

    /// Launch the target app hidden + unfocused if it isn't already running, returning the instance
    /// we started (or nil if it was already up / couldn't launch), so the caller can close it after.
    private static func launchIfNeeded(bundleID: String) async -> NSRunningApplication? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false // don't steal focus from the onboarding window
        config.hides = true // launch in the background, out of the way
        config.addsToRecentItems = false
        return try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private static func determinePermission(forBundleID bundleID: String, askUserIfNeeded: Bool) -> Bool {
        guard let idData = bundleID.data(using: .utf8) else { return false }
        var target = AEAddressDesc()
        let created = idData.withUnsafeBytes { raw -> OSStatus in
            OSStatus(AECreateDesc(typeApplicationBundleID, raw.baseAddress, raw.count, &target))
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, askUserIfNeeded
        )
        return status == noErr
    }
}
