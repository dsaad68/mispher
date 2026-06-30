import SwiftUI

/// A four-bar equalizer indicator next to the wordmark. Driven by a TimelineView
/// clock that is *paused* when idle, so the stopped state is provably static
/// (no `repeatForever` left running):
///   • recording → cyan, fast pulse
///   • paused    → amber, slow pulse
///   • idle      → gray, motionless
struct MicPulseView: View {
    enum Mode { case idle, recording, paused }

    var mode: Mode
    private let bars = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: mode == .idle)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0 ..< bars, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 2, height: height(bar: i, at: t))
                }
            }
            .frame(height: 12)
        }
    }

    private var color: Color {
        switch mode {
        case .recording: return Palette.accent
        case .paused: return Palette.warm
        case .idle: return Palette.fg3
        }
    }

    /// Pulse period in seconds — slow while paused, brisk while recording.
    private var period: Double {
        mode == .paused ? 1.8 : 0.6
    }

    private func height(bar i: Int, at t: Double) -> CGFloat {
        guard mode != .idle else { return 4 }
        let phase = Double(i) * 0.7
        let s = sin(2 * .pi * t / period + phase) // -1...1
        return 7.5 + 3.5 * s // 4...11
    }
}
