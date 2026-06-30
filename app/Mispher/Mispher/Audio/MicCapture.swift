import AVFoundation

/// One shared microphone capture layer built on `AVAudioEngine`.
///
/// Installs a tap on the input node and forwards each buffer as a `Sendable`
/// `AudioSamples` snapshot to a sink closure. The tap closure captures only the
/// sink (no `self`), so nothing non-`Sendable` crosses the audio-thread boundary.
@MainActor
final class MicCapture {
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    /// Current microphone authorization, without prompting. Drives the onboarding/settings status.
    static func permissionGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Ask for microphone access (prompts once on first use). Returns whether granted.
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Start capturing. `onSamples` is called on the realtime audio thread for
    /// every buffer. `deviceUID` selects a specific input device (an empty/unknown/unplugged UID
    /// falls back to the system default).
    func start(deviceUID: String? = nil, onSamples: @escaping @Sendable (AudioSamples) -> Void) throws {
        let input = engine.inputNode
        // Route capture to the chosen device before the format is read or the engine starts: the
        // input node's format reflects whichever device its audio unit is bound to. Best-effort -
        // if the device is gone, we keep the system default rather than failing to record.
        if let deviceUID, !deviceUID.isEmpty, let deviceID = AudioInputDevices.deviceID(forUID: deviceUID) {
            try? input.auAudioUnit.setDeviceID(deviceID)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw AppError.micUnavailable }

        // The tap block runs on AVAudioEngine's realtime thread, NOT the main
        // actor. It must be @Sendable so it doesn't inherit this method's
        // @MainActor isolation (otherwise Swift's executor check traps when the
        // audio thread invokes it). It captures only the @Sendable sink.
        let sink = onSamples
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            if let samples = AudioSamples(buffer: buffer) {
                sink(samples)
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }
}
