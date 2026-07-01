import SwiftUI

/// An interactive copy of the radial picker for Settings: the same wheel the overlay shows, but you
/// tap a quadrant to choose which mode it launches. Picking a mode swaps it with whatever quadrant
/// held it (via ``RadialLayout/assigning(_:to:)``), so the wheel always keeps all four modes. Clicks
/// are routed with the *same* ``RadialDirection/from(dx:dy:deadZone:)`` math the live wheel uses, so
/// the editor and the real thing can never disagree about which slice you hit.
struct RadialLayoutWheel: View {
    @Binding var layout: RadialLayout
    /// The quadrant whose action picker is open (drives the popover + the accent highlight).
    @State private var editing: RadialDirection?

    private let diameter: CGFloat = 224
    private let inner: CGFloat = 44 // dead-zone hub radius (also the wedge inner radius)
    private let labelRadius: CGFloat = 76

    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Palette.glassFill.opacity(0.6))
            ForEach(RadialLayout.order) { wedge($0) }
            hub
            Circle().strokeBorder(Palette.borderStrong, lineWidth: 0.75)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(SpatialTapGesture().onEnded { handleTap(at: $0.location) })
        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: layout)
        .animation(.easeOut(duration: 0.14), value: editing)
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        // Anchor the picker to the tapped slice (a unit point on its rim), arrow pointing outward, so
        // it pops out beside that slice instead of from the wheel's center.
        .popover(
            isPresented: presentedBinding,
            attachmentAnchor: .point(editing.map { rimAnchor($0) } ?? .center),
            arrowEdge: editing.map { popoverEdge($0) } ?? .top
        ) {
            if let editing { actionPicker(for: editing) }
        }
    }

    private func wedge(_ direction: RadialDirection) -> some View {
        let isOn = editing == direction
        let mid = direction.wheelCenterAngle
        let mode = layout.mode(at: direction)
        let radians = mid * .pi / 180
        let sector = AnnularSector(startAngle: .degrees(mid - 45), endAngle: .degrees(mid + 45), innerRadius: inner)
        return ZStack {
            sector.fill(isOn ? Palette.accent.opacity(0.22) : Palette.glassFill.opacity(0.14))
            sector.stroke(isOn ? Palette.accent.opacity(0.9) : Palette.border, lineWidth: isOn ? 1.5 : 0.75)
            VStack(spacing: 3) {
                Image(systemName: mode.symbol).font(.system(size: 16, weight: .semibold))
                Text(mode.label).font(.sans(10.5, weight: .medium))
            }
            .foregroundStyle(isOn ? Palette.accent : Palette.fg1)
            .offset(x: labelRadius * cos(radians), y: labelRadius * sin(radians))
        }
        .allowsHitTesting(false) // the wheel's single tap gesture owns hit-testing
    }

    private var hub: some View {
        ZStack {
            Circle().fill(Palette.bgDeep.opacity(0.92))
            Circle().strokeBorder(Palette.border, lineWidth: 0.75)
            Text("Tap a\nslice")
                .font(.sans(8.5, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.fg3)
        }
        .frame(width: inner * 2, height: inner * 2)
        .allowsHitTesting(false)
    }

    /// Map a tap in the wheel to a quadrant. The point is in the view's y-down space, so flip y to the
    /// AppKit y-up convention ``RadialDirection/from(dx:dy:deadZone:)`` expects; a tap in the hub
    /// (inside the dead-zone) returns `nil` and opens nothing.
    private func handleTap(at point: CGPoint) {
        let center = diameter / 2
        editing = RadialDirection.from(dx: point.x - center, dy: center - point.y, deadZone: inner)
    }

    private var presentedBinding: Binding<Bool> {
        Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    }

    /// A unit point on the quadrant's outer rim (0…1 in the wheel's bounds, y-down) that the popover
    /// arrow points at.
    private func rimAnchor(_ direction: RadialDirection) -> UnitPoint {
        let frac = 0.46 // fraction of the radius out to the rim
        let radians = direction.wheelCenterAngle * .pi / 180
        return UnitPoint(x: 0.5 + frac * cos(radians), y: 0.5 + frac * sin(radians))
    }

    /// The outward edge so each quadrant's popover sits on the wheel's outside near that slice.
    private func popoverEdge(_ direction: RadialDirection) -> Edge {
        switch direction {
        case .up: return .top
        case .right: return .trailing
        case .down: return .bottom
        case .left: return .leading
        }
    }

    private func actionPicker(for direction: RadialDirection) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Set \(direction.label) to")
                .font(.sans(10.5, weight: .medium))
                .foregroundStyle(Palette.fg2)
                .padding(.horizontal, 9)
                .padding(.bottom, 3)
            ForEach(RadialMode.allCases, id: \.self) { mode in
                Button {
                    layout = layout.assigning(mode, to: direction)
                    editing = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 16)
                        Text(mode.label)
                            .font(.sans(12, weight: .medium))
                            .foregroundStyle(Palette.fg)
                        Spacer(minLength: 16)
                        if layout.mode(at: direction) == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Palette.accent)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 172)
    }
}
