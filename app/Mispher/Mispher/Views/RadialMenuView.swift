import SwiftUI

/// A 90° annular wedge -- one slot of the radial picker -- drawn between an inner (dead-zone) and the
/// outer radius. Angles are SwiftUI screen angles (clockwise from +x, since the view's y points down).
/// Shared by the overlay wheel (``RadialMenuView``) and the Settings editor (``RadialLayoutWheel``).
struct AnnularSector: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var innerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The radial mode picker wheel: four glassy wedges (Transcribe / Translate / Rewrite / Ask) around a
/// hollow hub, the aimed wedge lit with the cyan accent. Reads ``RadialMenuPresenter`` for the live
/// highlight and the show/hide spring. Pure display -- ``RadialMenuController`` owns input + commit.
struct RadialMenuView: View {
    @Environment(RadialMenuPresenter.self) private var presenter

    private let wheel: CGFloat = 236
    private let inner: CGFloat = 42 // visual dead-zone hub radius
    private let labelRadius: CGFloat = 80
    private let appear = Animation.spring(response: 0.32, dampingFraction: 0.74)
    private let highlightAnim = Animation.spring(response: 0.26, dampingFraction: 0.7)

    /// The direction the Ask slice occupies in the current layout (where the New/Continue split shows).
    private var askDirection: RadialDirection { presenter.layout.direction(of: .ask) }

    /// The Ask slice reveals its New / Continue split only while it's the aimed slice (and a
    /// conversation is open to resume). Otherwise it reads as a single "Ask" slot like the others, so
    /// the split is a hover affordance rather than always-on clutter.
    private var askExpanded: Bool { presenter.askSplit && presenter.highlighted == askDirection }

    var body: some View {
        ZStack {
            base
            ForEach(RadialLayout.order, id: \.self) { wedgeOrSplit($0) }
            hub
            ForEach(RadialLayout.order, id: \.self) { labelOrSplit($0) }
            Circle().strokeBorder(Palette.borderStrong, lineWidth: 0.75)
        }
        .frame(width: wheel, height: wheel)
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 14)
        .scaleEffect(presenter.shown ? presenter.scale : presenter.scale * 0.82)
        .opacity(presenter.shown ? 1 : 0)
        .animation(appear, value: presenter.shown)
        .animation(highlightAnim, value: presenter.highlighted)
        .animation(highlightAnim, value: presenter.askChoice)
        .frame(maxWidth: .infinity, maxHeight: .infinity) // center within the larger (padded) panel
    }

    private var base: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Palette.glassFill.opacity(0.6))
        }
    }

    /// The aimed Ask slice splits into two New/Continue halves; every other slice (and an un-aimed Ask
    /// slice) draws as a single wedge.
    @ViewBuilder private func wedgeOrSplit(_ direction: RadialDirection) -> some View {
        if direction == askDirection, askExpanded {
            askWedges(direction)
        } else {
            wedge(direction)
        }
    }

    private func wedge(_ direction: RadialDirection) -> some View {
        sector(.degrees(direction.wheelCenterAngle - 45), .degrees(direction.wheelCenterAngle + 45),
               on: presenter.highlighted == direction)
    }

    /// The two 45° halves of the aimed Ask slice: New toward `mid + 45°`, Continue toward `mid - 45°`,
    /// the one the pointer aims at lit (see ``RadialAskChoice/from(dx:dy:wedge:)``).
    private func askWedges(_ direction: RadialDirection) -> some View {
        let mid = direction.wheelCenterAngle
        return ZStack {
            sector(.degrees(mid), .degrees(mid + 45), on: presenter.askChoice == .new)
            sector(.degrees(mid - 45), .degrees(mid), on: presenter.askChoice == .resume)
        }
    }

    /// One annular wedge (or half-wedge), lit with the accent when `on`. Shared by the plain wedges
    /// and the split Ask halves so they highlight identically.
    private func sector(_ start: Angle, _ end: Angle, on: Bool) -> some View {
        let sector = AnnularSector(startAngle: start, endAngle: end, innerRadius: inner)
        return sector
            .fill(on ? Palette.accent.opacity(0.22) : Color.clear)
            .overlay(sector.stroke(on ? Palette.accent.opacity(0.9) : Palette.border, lineWidth: on ? 1.5 : 0.75))
            .shadow(color: on ? Palette.accentGlow : .clear, radius: on ? 12 : 0)
    }

    private var hub: some View {
        let diameter = inner * 2
        return ZStack {
            Circle().fill(Palette.bgDeep.opacity(0.92))
            Circle().strokeBorder(Palette.border, lineWidth: 0.75)
            Text(presenter.highlighted == nil ? "Release\nto cancel" : "Release\nto start")
                .font(.sans(8.5, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.fg3)
        }
        .frame(width: diameter, height: diameter)
    }

    /// The aimed Ask slice shows two labels ("New" / "Continue") at its sub-centers; every other slice
    /// (and an un-aimed Ask slice) shows its single mode label.
    @ViewBuilder private func labelOrSplit(_ direction: RadialDirection) -> some View {
        if direction == askDirection, askExpanded {
            askLabels(direction)
        } else {
            label(direction)
        }
    }

    private func label(_ direction: RadialDirection) -> some View {
        let mode = presenter.layout.mode(at: direction)
        return slotLabel(angle: direction.wheelCenterAngle, symbol: mode.symbol, text: mode.label,
                         on: presenter.highlighted == direction)
    }

    /// The New / Continue labels for the aimed Ask slice, sat at the two sub-centers (`mid ± 22.5°`)
    /// so each lines up with its half. Drawn `compact` so both fit inside the one 90° wedge.
    private func askLabels(_ direction: RadialDirection) -> some View {
        let mid = direction.wheelCenterAngle
        return ZStack {
            slotLabel(angle: mid + 22.5, symbol: RadialMode.ask.symbol, text: "New",
                      compact: true, on: presenter.askChoice == .new)
            slotLabel(angle: mid - 22.5, symbol: "arrow.clockwise", text: "Continue",
                      compact: true, on: presenter.askChoice == .resume)
        }
    }

    /// An icon-over-text label placed at `labelRadius` along `angle` (SwiftUI screen degrees), lit with
    /// the accent when `on`. `compact` shrinks it so two fit in the split Ask wedge. Shared by the plain
    /// slot labels and the split Ask labels.
    private func slotLabel(angle: Double, symbol: String, text: String,
                           compact: Bool = false, on: Bool) -> some View {
        let radians = angle * .pi / 180
        return VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 14 : 17, weight: .semibold))
            Text(text)
                .font(.sans(compact ? 9.5 : 10.5, weight: .medium))
        }
        .foregroundStyle(on ? Palette.accent : Palette.fg1)
        .offset(x: labelRadius * cos(radians), y: labelRadius * sin(radians))
    }
}
