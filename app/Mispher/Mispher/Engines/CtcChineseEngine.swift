import CoreML
import FluidAudio

/// Batch backend for Parakeet CTC Chinese (Mandarin zh-CN) via FluidAudio's
/// `CtcZhCnManager`. Wrapped by `BatchReprocessEngine` to produce live partials.
/// The model ships int8 (default) and fp32 encoders in one download; `useInt8`
/// chooses which the manager loads.
actor CtcZhCnBackend: BatchTranscriber {
    private let useInt8: Bool
    private var manager: CtcZhCnManager?

    init(useInt8: Bool) {
        self.useInt8 = useInt8
    }

    func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        if manager != nil { return }

        status("Loading Parakeet CTC Chinese…")
        // NB: the CTC preprocessor/encoder are fixed-shape (~15 s of audio), so
        // we keep FluidAudio's default cap — longer turns are truncated.
        let manager = try await CtcZhCnManager.load(useInt8Encoder: useInt8) { progress in
            status("Downloading model… \(Int(progress.fractionCompleted * 100))%")
        }
        self.manager = manager
        status("Model ready (ANE)")
    }

    func transcribe(samples: [Float], sourceRate: Double) async throws -> String {
        guard let manager else { return "" }
        // CtcZhCnManager expects 16 kHz mono samples.
        let samples16k = Resampler.to16kMono(samples, sourceRate: sourceRate)
        let raw = try await manager.transcribe(audio: samples16k)
        return Self.collapseCJKSpacing(raw)
    }

    /// The CTC decoder emits one token per character separated by spaces, but
    /// Mandarin doesn't use spaces. Drop any space that sits next to a CJK
    /// character (ideograph or CJK/fullwidth punctuation) while preserving the
    /// occasional space between Latin/numeric runs.
    static func collapseCJKSpacing(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() {
            if ch == " " {
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                let next = j < chars.count ? chars[j] : nil
                if let prev = out.last, isCJK(prev) || (next.map(isCJK) ?? false) {
                    continue // drop a space adjacent to a CJK character
                }
            }
            out.append(ch)
        }
        return String(out)
    }

    private static func isCJK(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x3000 ... 0x303F).contains(v) // CJK symbols & punctuation
                || (0x3400 ... 0x9FFF).contains(v) // CJK ideographs (+ ext A)
                || (0xF900 ... 0xFAFF).contains(v) // compatibility ideographs
                || (0xFF00 ... 0xFFEF).contains(v) { // fullwidth forms (，？！…)
                return true
            }
        }
        return false
    }
}
