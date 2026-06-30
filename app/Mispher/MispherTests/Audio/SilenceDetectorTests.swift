@testable import Mispher
import Testing

/// Time-based behavior of the hands-free ``SilenceDetector``: it fires once after a post-speech
/// silence exceeds the timeout, ignores lead-in silence, and honors reset / disarm. A small fake
/// sample rate keeps the buffers tiny while still exercising the `count / sampleRate` timing.
struct SilenceDetectorTests {
    /// Loud samples (RMS above the ~0.012 threshold) count as speech.
    private func speech(_ seconds: Double, rate: Double = 1000) -> AudioSamples {
        AudioSamples(samples: [Float](repeating: 0.2, count: Int(seconds * rate)), sampleRate: rate)
    }

    /// Quiet samples (RMS below the threshold) count as silence.
    private func silence(_ seconds: Double, rate: Double = 1000) -> AudioSamples {
        AudioSamples(samples: [Float](repeating: 0, count: Int(seconds * rate)), sampleRate: rate)
    }

    @Test func firesAfterPostSpeechSilence() async {
        await confirmation { fired in
            let detector = SilenceDetector()
            await detector.arm(timeout: 1.0) { fired() }
            await detector.ingest(speech(0.3))
            await detector.ingest(silence(1.5)) // past the timeout
        }
    }

    @Test func ignoresLeadInSilence() async {
        await confirmation(expectedCount: 0) { fired in
            let detector = SilenceDetector()
            await detector.arm(timeout: 1.0) { fired() }
            await detector.ingest(silence(2.0)) // no speech heard yet, so it's ignored
        }
    }

    @Test func firesOncePerArm() async {
        await confirmation(expectedCount: 1) { fired in
            let detector = SilenceDetector()
            await detector.arm(timeout: 1.0) { fired() }
            await detector.ingest(speech(0.3))
            await detector.ingest(silence(2.0)) // crosses the timeout -> fires
            await detector.ingest(silence(2.0)) // already fired -> no-op
        }
    }

    @Test func resetIgnoresSilenceUntilNewSpeech() async {
        await confirmation(expectedCount: 0) { fired in
            let detector = SilenceDetector()
            await detector.arm(timeout: 1.0) { fired() }
            await detector.ingest(speech(0.3))
            await detector.ingest(silence(0.5)) // below the timeout
            await detector.reset() // clears the heard-voice flag and the silence count
            await detector.ingest(silence(2.0)) // lead-in silence again after reset
        }
    }

    @Test func disarmStopsDetection() async {
        await confirmation(expectedCount: 0) { fired in
            let detector = SilenceDetector()
            await detector.arm(timeout: 1.0) { fired() }
            await detector.disarm()
            await detector.ingest(speech(0.3))
            await detector.ingest(silence(2.0))
        }
    }

    /// A configurable timeout (the user's `silenceTimeout` setting) holds off until its own
    /// threshold: a 2.5s timeout does not fire after only 2s of silence, but does after 3s.
    @Test func honorsACustomTimeout() async {
        await confirmation(expectedCount: 0) { fired in
            let detector = SilenceDetector()
            await detector.arm(timeout: 2.5) { fired() }
            await detector.ingest(speech(0.3))
            await detector.ingest(silence(2.0)) // below the 2.5s timeout → no fire
        }
        await confirmation(expectedCount: 1) { fired in
            let detector = SilenceDetector()
            await detector.arm(timeout: 2.5) { fired() }
            await detector.ingest(speech(0.3))
            await detector.ingest(silence(3.0)) // past the 2.5s timeout → fires
        }
    }
}
