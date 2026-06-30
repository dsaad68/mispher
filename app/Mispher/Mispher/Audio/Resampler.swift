import AVFoundation

/// One-shot resampler: mono float samples at an arbitrary source rate → 16 kHz
/// mono float. Needed by the Parakeet CTC Chinese path, which expects 16 kHz
/// `[Float]` directly (the TDT and Nemotron managers resample internally).
enum Resampler {
    static func to16kMono(_ samples: [Float], sourceRate: Double) -> [Float] {
        guard sourceRate != 16000 else { return samples }
        guard
            !samples.isEmpty,
            let inFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                channels: 1, interleaved: false
            ),
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let inBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)
            )
        else { return samples }

        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            inBuffer.floatChannelData![0].update(from: base, count: samples.count)
        }

        let capacity = AVAudioFrameCount(Double(samples.count) * 16000 / sourceRate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
        else { return samples }

        // `AVAudioConverterInputBlock` is `@Sendable`, but it runs synchronously
        // on this thread for the duration of `convert`, so the captured state is
        // never touched concurrently. `nonisolated(unsafe)` opts these bindings
        // out of the (here spurious) Sendable/exclusivity checks.
        nonisolated(unsafe) let source = inBuffer
        nonisolated(unsafe) var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inStatus in
            if provided {
                inStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inStatus.pointee = .haveData
            return source
        }

        guard status != .error, conversionError == nil else { return samples }

        let count = Int(outBuffer.frameLength)
        guard count > 0, let channel = outBuffer.floatChannelData?[0] else { return samples }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }
}
