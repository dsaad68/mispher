import SwiftUI

/// The notch's app glyph - copilot-island's `CopilotIcon`, adapted to Mispher: a logo-gradient
/// `sparkles` symbol (Mispher ships no "AppLogo" image asset) that breathes while the agent works.
struct NotchAppIcon: View {
    let size: CGFloat
    var animate: Bool = false

    /// 0 = dim/small, 1 = full - driven by a repeatForever breathing animation.
    @State private var breath: Double = 0

    init(size: CGFloat = 16, animate: Bool = false) {
        self.size = size
        self.animate = animate
    }

    private var opacity: Double { animate ? (0.75 + 0.25 * breath) : 1.0 }
    private var scale: Double { animate ? (0.97 + 0.03 * breath) : 1.0 }

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Color.logoGradient)
            .frame(width: size, height: size)
            .opacity(opacity)
            .scaleEffect(scale)
            .animation(animate ? .easeInOut(duration: 1.25) : .default, value: breath)
            .onAppear {
                if animate {
                    withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) { breath = 1 }
                }
            }
    }
}

/// Animated spinner for the processing state: a single clean arc in the app's accent color (matching
/// the brand mark), rounded caps, spinning smoothly. No gradient - an angular gradient on a trimmed
/// arc produces seam/cap artifacts (the "two bright dots").
struct ProcessingSpinner: View {
    @State private var rotation: Double = 0

    private let size: CGFloat = 13

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) { rotation = 360 }
            }
    }
}

/// Minimal 4-point starburst for the closed-notch processing state - logo gradient, gentle rotation.
/// Ported 1:1 from copilot-island.
struct StarburstView: View {
    var size: CGFloat = 12
    @State private var rotation: Double = 0

    private let rayLengthRatio: CGFloat = 0.4

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = min(canvasSize.width, canvasSize.height) * rayLengthRatio / 2
            var path = Path()
            for index in 0 ..< 4 {
                let angle = Double(index) * 90 * .pi / 180
                let x = center.x + CGFloat(cos(angle)) * radius
                let y = center.y + CGFloat(sin(angle)) * radius
                path.move(to: center)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [.logoPurple, .logoCyan]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: canvasSize.width, y: canvasSize.height)
                ),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation))
        .onAppear {
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) { rotation = 360 }
        }
    }
}
