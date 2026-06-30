import ApplicationServices
import Foundation

/// Microphone-device selection and the macOS access permissions (Microphone, Accessibility,
/// Automation), split out of ``TranscriptionViewModel`` so the main file stays within the length
/// limit. The onboarding "Microphone & access" step and the Settings banner drive these.
@MainActor
extension TranscriptionViewModel {
    // MARK: - Input device

    /// Re-enumerate the available input devices into ``availableInputDevices``.
    func refreshInputDevices() { availableInputDevices = AudioInputDevices.available() }

    /// Display name for the current microphone selection: "System Default" when unset, the device's
    /// name when known, else a hint that the saved device is gone.
    var selectedInputDeviceLabel: String {
        guard !selectedInputDeviceUID.isEmpty else { return "System Default" }
        return availableInputDevices.first { $0.uid == selectedInputDeviceUID }?.name ?? "Unavailable device"
    }

    // MARK: - Permissions (global shortcuts need Accessibility trust; recording needs Microphone)

    /// Re-read Accessibility trust into `accessibilityTrusted` (the Settings banner observes it).
    func refreshAccessibilityTrust() { accessibilityTrusted = AXIsProcessTrusted() }

    /// Show the system Accessibility prompt (and surface the app in Privacy settings).
    func promptAccessibility() {
        // The key constant `kAXTrustedCheckOptionPrompt` is a non-concurrency-safe global;
        // its documented value is this literal.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Re-read microphone authorization into ``micPermissionGranted``.
    func refreshMicPermission() { micPermissionGranted = MicCapture.permissionGranted() }

    /// Show the system Microphone prompt (first time) and record the outcome.
    func requestMicrophonePermission() async {
        micPermissionGranted = await mic.requestPermission()
    }

    /// Show the macOS Automation prompt for Apple Notes (used by the Ask agent) and report whether
    /// it's now allowed. Launches Notes hidden first so the prompt actually fires (the check needs a
    /// running target). Best-effort: it only matters once the user asks the agent to touch Notes.
    @discardableResult
    func promptAutomationAccess() async -> Bool {
        await AutomationAccess.requestPermission(forBundleID: AutomationAccess.appleNotesBundleID)
    }
}
