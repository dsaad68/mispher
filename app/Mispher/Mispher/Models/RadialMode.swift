import Carbon.HIToolbox
import Foundation

/// One of the four cardinal slots in the radial mode picker. The wheel pops at the cursor when the
/// trigger key is held; the user aims the pointer (or presses an arrow) to highlight a slot, and a
/// release launches the slot's mode. Pure value type with no AppKit/UI state, so the direction math
/// and the wheel layout are unit-tested exactly like ``Hotkey`` / ``ActivationMode``.
enum RadialDirection: String, CaseIterable, Sendable, Hashable, Identifiable {
    case up, right, down, left

    var id: String { rawValue }

    /// The wedge's center angle in SwiftUI screen degrees (clockwise from +x, since the view's y
    /// points down): up = top (-90°), right = 0°, down = bottom (90°), left = 180°. Shared by the
    /// overlay wheel and the Settings editor so both draw identically.
    var wheelCenterAngle: Double {
        switch self {
        case .up: return -90
        case .right: return 0
        case .down: return 90
        case .left: return 180
        }
    }

    /// The slot the cursor is pointing at, from the cursor offset relative to the wheel center.
    /// `dx`/`dy` are in AppKit screen coordinates (y grows upward). Returns `nil` inside the
    /// dead-zone (`r < deadZone`) so a release there cancels without launching anything.
    ///
    /// The plane is split into four 90° sectors centered on the cardinals. Boundaries are pinned
    /// deterministically (a tie lands on the sector that owns the closing edge) so the tests can
    /// assert exact behavior: `±45°`→ right/down, `±135°`→ up/left.
    static func from(dx: CGFloat, dy: CGFloat, deadZone: CGFloat) -> RadialDirection? {
        guard hypot(dx, dy) >= deadZone else { return nil }
        let a = atan2(dy, dx) // (-pi, pi], 0 = right, +pi/2 = up
        let q = Double.pi / 4
        let angle = Double(a)
        if angle > q, angle <= 3 * q { return .up }
        if angle > -q, angle <= q { return .right }
        if angle > -3 * q, angle <= -q { return .down }
        return .left // |angle| > 3*q
    }

    /// The slot an arrow key selects, or `nil` for any non-arrow key (so the caller leaves the
    /// highlight untouched and the key passes through).
    static func from(arrowKeyCode keyCode: UInt16) -> RadialDirection? {
        switch Int(keyCode) {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        default: return nil
        }
    }

    /// Short name for the Settings action picker (e.g. "Set Up to…").
    var label: String {
        switch self {
        case .up: return "Up"
        case .right: return "Right"
        case .down: return "Down"
        case .left: return "Left"
        }
    }
}

/// The four modes the radial picker can launch -- a subset of ``RecordIntent`` (askContinue is
/// excluded). Each carries its wheel icon + label, the single source of truth shared by the wheel,
/// the controller's commit, the Settings editor, and the tests.
enum RadialMode: String, CaseIterable, Sendable, Hashable {
    case transcription, translate, rewrite, ask

    /// The recording intent this slot launches.
    var intent: RecordIntent {
        switch self {
        case .transcription: return .transcription
        case .translate: return .translate
        case .rewrite: return .rewrite
        case .ask: return .ask
        }
    }

    var symbol: String {
        switch self {
        case .transcription: return "waveform"
        case .translate: return "translate"
        case .rewrite: return "wand.and.stars"
        case .ask: return "sparkles"
        }
    }

    var label: String {
        switch self {
        case .transcription: return "Transcribe"
        case .translate: return "Translate"
        case .rewrite: return "Rewrite"
        case .ask: return "Ask"
        }
    }
}

/// Which half of the split Ask slice the dial is aiming at. When the dial opens onto an open Ask
/// conversation, the Ask wedge splits into two 45° halves: ``new`` starts a brand-new conversation
/// (``RecordIntent/ask``), ``resume`` continues the active `~/.mispher` thread (``RecordIntent/askContinue``).
/// Purely a dial affordance -- with no conversation to continue the Ask slice stays whole and starts fresh.
enum RadialAskChoice: String, CaseIterable, Sendable, Hashable {
    case new, resume

    /// The recording intent this choice launches.
    var intent: RecordIntent { self == .resume ? .askContinue : .ask }

    /// Which half the aim falls in, *given it already resolved to the Ask wedge*. `dx`/`dy` are AppKit
    /// screen coords (y up) from the wheel center; `wedge` is the direction the Ask slice occupies.
    /// The slice spans ``RadialDirection/wheelCenterAngle`` ± 45°; the half toward `mid + 45°` (where
    /// the "New" label sits, at `mid + 22.5°`) is ``new``, the `mid - 45°` half ("Continue") is ``resume``.
    static func from(dx: CGFloat, dy: CGFloat, wedge: RadialDirection) -> RadialAskChoice {
        // The view draws in SwiftUI screen angles (clockwise from +x, y down); the aim is AppKit (y up),
        // so the aim's screen angle is `atan2(-dy, dx)`. New owns (mid, mid + 45], resume [mid - 45, mid].
        let aim = atan2(Double(-dy), Double(dx)) * 180 / .pi
        var delta = (aim - wedge.wheelCenterAngle).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        return delta >= 0 ? .new : .resume
    }
}

/// The user-editable mapping of wheel directions to modes. Always a bijection over all four
/// ``RadialMode`` cases, so every mode stays reachable and none is duplicated. Assigning a mode to a
/// direction swaps it with whoever held it, so the editor can never produce an invalid wheel.
struct RadialLayout: Equatable, Sendable {
    /// The mode at each direction, in the fixed order ``order`` ([up, right, down, left]).
    private var modes: [RadialMode]

    /// Direction order used for storage, iteration, and the editor rows.
    static let order: [RadialDirection] = [.up, .right, .down, .left]

    /// Default: up = Transcribe, right = Translate, down = Rewrite, left = Ask.
    static let `default` = RadialLayout(modes: [.transcription, .translate, .rewrite, .ask])

    private init(modes: [RadialMode]) { self.modes = modes }

    /// The mode shown in `direction`.
    func mode(at direction: RadialDirection) -> RadialMode { modes[index(of: direction)] }

    /// The direction currently holding `mode`.
    func direction(of mode: RadialMode) -> RadialDirection {
        Self.order[modes.firstIndex(of: mode) ?? 0]
    }

    /// Put `mode` in `direction`, swapping it with whatever direction currently holds it so the
    /// layout stays a bijection -- this is how "move Ask to Up" pushes Up's old mode into Ask's slot.
    func assigning(_ mode: RadialMode, to direction: RadialDirection) -> RadialLayout {
        let target = index(of: direction)
        guard modes[target] != mode, let source = modes.firstIndex(of: mode) else { return self }
        var next = modes
        next.swapAt(target, source)
        return RadialLayout(modes: next)
    }

    private func index(of direction: RadialDirection) -> Int {
        Self.order.firstIndex(of: direction) ?? 0
    }

    // MARK: Persistence (the four mode raw values in direction order)

    var rawValues: [String] { modes.map(\.rawValue) }

    /// Rebuild from stored raw values; returns `nil` (so the caller falls back to ``default``) unless
    /// the values are a full permutation of the four modes, so a corrupt/partial store can't drop one.
    init?(rawValues: [String]) {
        let parsed = rawValues.compactMap(RadialMode.init(rawValue:))
        guard parsed.count == RadialMode.allCases.count, Set(parsed) == Set(RadialMode.allCases) else { return nil }
        modes = parsed
    }
}
