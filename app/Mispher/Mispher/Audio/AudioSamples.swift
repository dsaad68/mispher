import AVFoundation

/// A `Sendable` snapshot of one captured audio buffer.
///
/// The microphone tap runs on a real-time audio thread and hands us a
/// non-`Sendable` `AVAudioPCMBuffer`. We immediately copy it into this value
/// type (mono float samples + the capture sample rate) so it can cross
/// concurrency boundaries safely. Each engine reconstructs whatever it needs
/// (Parakeet rebuilds an `AVAudioPCMBuffer`; Qwen resamples to 16 kHz WAV).
struct AudioSamples: Sendable {
    /// Mono PCM float samples in [-1, 1].
    let samples: [Float]
    /// Sample rate of `samples` (the input node's native rate, e.g. 48000).
    let sampleRate: Double
}

extension AudioSamples {
    /// Copy + downmix a capture buffer into a `Sendable` snapshot.
    /// Returns nil for empty or non-float (interleaved) buffers.
    init?(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        if channels <= 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: channelData[0], count: frames)
            }
        } else {
            // Average all channels down to mono.
            for frame in 0 ..< frames {
                var acc: Float = 0
                for channel in 0 ..< channels {
                    acc += channelData[channel][frame]
                }
                mono[frame] = acc / Float(channels)
            }
        }

        samples = mono
        sampleRate = buffer.format.sampleRate
    }
}
