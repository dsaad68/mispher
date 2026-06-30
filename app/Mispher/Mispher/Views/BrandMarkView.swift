import SwiftUI

/// The Mispher glyph: concentric rings crossed by a plus — the `hud-brand-mark`
/// logo from the prototype, drawn in the accent color.
struct BrandMarkView: View {
    var size: CGFloat = 20

    var body: some View {
        Canvas { context, canvas in
            let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let r = min(canvas.width, canvas.height) / 2
            let stroke = StrokeStyle(lineWidth: r * 0.14, lineCap: .round)

            // Outer ring (faint)
            context.stroke(
                Path(ellipseIn: CGRect(x: c.x - r * 0.92, y: c.y - r * 0.92,
                                       width: r * 1.84, height: r * 1.84)),
                with: .color(Palette.accent.opacity(0.4)),
                style: stroke
            )
            // Inner ring
            context.stroke(
                Path(ellipseIn: CGRect(x: c.x - r * 0.56, y: c.y - r * 0.56,
                                       width: r * 1.12, height: r * 1.12)),
                with: .color(Palette.accent),
                style: stroke
            )
            // Crosshair
            var cross = Path()
            cross.move(to: CGPoint(x: c.x, y: c.y - r * 0.92))
            cross.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.92))
            cross.move(to: CGPoint(x: c.x - r * 0.92, y: c.y))
            cross.addLine(to: CGPoint(x: c.x + r * 0.92, y: c.y))
            context.stroke(cross, with: .color(Palette.accent.opacity(0.55)), style: stroke)
        }
        .frame(width: size, height: size)
    }
}
