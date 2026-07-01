import AVFoundation

/// Holds the one-and-only input buffer for a single-shot `AVAudioConverter` run.
/// `take()` returns it exactly once, so the converter sees "data, then end".
private final class ConversionState: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Converts mono float samples (at an arbitrary source rate) into a 16 kHz mono
/// 16-bit PCM WAV `Data` blob — the format the Qwen3-ASR `llama-server` expects.
enum WavEncoder {
    /// Resample (if needed) to 16 kHz mono and wrap as a WAV container.
    static func wav16kMonoData(fromMono samples: [Float], sourceRate: Double) -> Data? {
        guard !samples.isEmpty else { return nil }
        let targetRate = 16000.0

        let samples16k: [Float]
        if abs(sourceRate - targetRate) < 1 {
            samples16k = samples
        } else {
            guard let resampled = resample(samples, from: sourceRate, to: targetRate) else { return nil }
            samples16k = resampled
        }

        var pcm = [Int16](repeating: 0, count: samples16k.count)
        for i in 0 ..< samples16k.count {
            let clamped = max(-1.0, min(1.0, samples16k[i]))
            pcm[i] = Int16(clamped * 32767.0)
        }
        return wavContainer(pcm16: pcm, sampleRate: Int(targetRate))
    }

    // MARK: - Resampling

    private static func resample(_ samples: [Float], from src: Double, to dst: Double) -> [Float]? {
        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src, channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: dst, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }

        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let capacity = AVAudioFrameCount(Double(samples.count) * dst / src + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        // Single-shot conversion: feed the whole input buffer once, then signal end.
        // `state` lives in a class box so the @Sendable input block mutates it safely.
        let state = ConversionState(buffer: inBuffer)
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inStatus in
            guard let buffer = state.take() else {
                inStatus.pointee = .noDataNow
                return nil
            }
            inStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return nil }

        let count = Int(outBuffer.frameLength)
        guard count > 0, let channel = outBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }

    // MARK: - WAV container

    private static func wavContainer(pcm16: [Int16], sampleRate: Int) -> Data {
        let numChannels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = pcm16.count * 2

        func le32(_ value: Int) -> [UInt8] {
            let v = UInt32(value)
            return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        func le16(_ value: Int) -> [UInt8] {
            let v = UInt16(value)
            return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
        }

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: le32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: le32(16)) // fmt chunk size
        data.append(contentsOf: le16(1)) // PCM
        data.append(contentsOf: le16(numChannels))
        data.append(contentsOf: le32(sampleRate))
        data.append(contentsOf: le32(byteRate))
        data.append(contentsOf: le16(blockAlign))
        data.append(contentsOf: le16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: le32(dataSize))
        pcm16.withUnsafeBytes { raw in
            data.append(contentsOf: raw) // Int16 is little-endian on Apple Silicon
        }
        return data
    }
}
