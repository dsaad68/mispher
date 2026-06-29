import Foundation

/// Watches the live mic stream and fires once after the user stops speaking, so a hands-free
/// recording can finish without a stop press. It's fed every captured buffer from the
/// transcription consumer; it tracks short-term loudness (RMS) and, once speech has been heard,
/// starts counting silence -- when the quiet stretch passes `timeout` it calls back exactly once
/// (until re-armed).
///
/// An `actor` because it's armed/reset from the main actor but fed from the detached audio
/// consumer task; the small mutable counters must stay consistent across both.
actor SilenceDetector {
    /// Absolute RMS floor (mono samples in [-1, 1]); anything quieter is always silence. ~ -38 dBFS.
    private static let floor: Float = 0.012
    /// A buffer *also* counts as silence once it drops below this fraction of the loudest speech
    /// heard. A mic/room whose idle level sits above the absolute floor would otherwise never read
    /// as silent - so a hands-free recording would never auto-end; comparing against the speech
    /// level we actually heard adapts the cutoff to the environment.
    private static let relativeFraction: Float = 0.1
    /// How long the input must stay quiet (after speech) before finishing.
    static let defaultTimeout: TimeInterval = 1.6

    private var armed = false
    private var fired = false
    private var heardVoice = false
    private var silentSeconds: TimeInterval = 0
    /// Loudest RMS seen since arming, so the relative silence cutoff tracks the actual speech level.
    private var speechPeak: Float = 0
    private var timeout: TimeInterval = SilenceDetector.defaultTimeout
    private var onSilence: (@Sendable () -> Void)?

    /// Begin watching. `onSilence` runs once when a post-speech silence exceeds `timeout`.
    func arm(timeout: TimeInterval = SilenceDetector.defaultTimeout, onSilence: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.onSilence = onSilence
        armed = true
        fired = false
        heardVoice = false
        silentSeconds = 0
        speechPeak = 0
    }

    /// Stop watching and drop the callback.
    func disarm() {
        armed = false
        onSilence = nil
        heardVoice = false
        silentSeconds = 0
        speechPeak = 0
    }

    /// Clear the running silence count (e.g. on resume) without disarming. Keeps the learned speech
    /// level so the adaptive cutoff survives a pause.
    func reset() {
        heardVoice = false
        silentSeconds = 0
        fired = false
    }

    /// Feed one captured buffer. No-op unless armed and not yet fired.
    func ingest(_ samples: AudioSamples) {
        guard armed, !fired, !samples.samples.isEmpty, samples.sampleRate > 0 else { return }
        let level = rms(samples.samples)
        speechPeak = max(speechPeak, level)
        // Silence = below the absolute floor, OR collapsed to a small fraction of the speech we
        // heard (the latter rescues noisy mics whose idle level is above the floor).
        let silenceCutoff = max(Self.floor, speechPeak * Self.relativeFraction)
        if level >= silenceCutoff {
            heardVoice = true
            silentSeconds = 0
            return
        }
        guard heardVoice else { return } // don't count the lead-in before the first words
        silentSeconds += Double(samples.samples.count) / samples.sampleRate
        if silentSeconds >= timeout {
            fired = true
            onSilence?()
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
