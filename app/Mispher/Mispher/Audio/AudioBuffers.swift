import AVFoundation

/// Shared conversion from a `Sendable` `AudioSamples` snapshot into a 1-channel
/// float `AVAudioPCMBuffer`. FluidAudio's managers resample to 16 kHz mono
/// internally, so the native capture rate is fine here.
enum AudioBuffers {
    static func make(_ samples: AudioSamples) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: samples.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.samples.count)
            )
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.samples.count)
        samples.samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            buffer.floatChannelData![0].update(from: base, count: samples.samples.count)
        }
        return buffer
    }
}
