import AVFoundation
import os

/// Headless smoke test for the realtime microphone tap. Installs the same tap
/// `MicCapture` uses and pumps buffers for a few seconds. If the tap block were
/// still inheriting `@MainActor` isolation, the audio thread would trap here.
@MainActor
enum AudioSelfTest {
    static func run() async {
        let mic = MicCapture()
        let counter = BufferCounter()

        let granted = await mic.requestPermission()
        log("permission granted=\(granted)")
        guard granted else {
            log("no mic permission — cannot exercise capture")
            return
        }

        do {
            try mic.start { samples in counter.add(frames: samples.samples.count) }
            log("tap installed; capturing for 4s…")
        } catch {
            log("mic.start error: \(error)")
            return
        }

        try? await Task.sleep(for: .seconds(4))
        mic.stop()

        let (buffers, frames) = counter.snapshot()
        log("RESULT buffers=\(buffers) frames=\(frames) — no isolation crash")
    }

    /// Feed a WAV/audio file through the real `ParakeetEngine` and print the
    /// streaming partials + final transcript. Validates the full English
    /// pipeline end-to-end without a live microphone.
    static func runParakeet(path: String) async {
        guard !path.isEmpty else { log("no MISPHER_SELFTEST_FILE provided"); return }
        let url = URL(fileURLWithPath: path)

        let engine = ParakeetEngine()
        do {
            try await engine.prepare { message in log("prepare: \(message)") }
        } catch {
            log("prepare failed: \(error)")
            return
        }

        try? await engine.startSession { text in
            FileHandle.standardError.write(Data("PARTIAL: \(text)\n".utf8))
        }

        guard let audio = readMono(url: url) else {
            log("could not read audio at \(path)")
            return
        }
        log("feeding \(audio.samples.count) samples @ \(Int(audio.sampleRate))Hz")

        // Feed in ~100ms slices to mimic streaming capture.
        let sliceSize = max(1, Int(audio.sampleRate * 0.1))
        var index = 0
        while index < audio.samples.count {
            let end = min(index + sliceSize, audio.samples.count)
            let chunk = AudioSamples(samples: Array(audio.samples[index ..< end]), sampleRate: audio.sampleRate)
            await engine.append(chunk)
            index = end
        }

        do {
            let final = try await engine.finishSession()
            log("FINAL: \(final)")
        } catch {
            log("finish failed: \(error)")
        }
    }

    private static func readMono(url: URL) -> AudioSamples? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            return nil
        }
        do { try file.read(into: buffer) } catch { return nil }
        return AudioSamples(buffer: buffer)
    }

    private nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Thread-safe counter; the tap closure increments it from the audio thread.
private final class BufferCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (buffers: 0, frames: 0))
    func add(frames: Int) {
        state.withLock { $0.buffers += 1; $0.frames += frames }
    }

    func snapshot() -> (Int, Int) {
        state.withLock { ($0.buffers, $0.frames) }
    }
}
