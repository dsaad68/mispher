import AppKit
import Carbon.HIToolbox

/// One side-specific modifier key. Unlike `NSEvent.ModifierFlags` (device-independent),
/// this distinguishes left from right so a shortcut can require, say, *left* Option.
enum ModifierSide: String, Codable, CaseIterable, Sendable, Hashable {
    case leftCommand, rightCommand
    case leftOption, rightOption
    case leftControl, rightControl
    case leftShift, rightShift
}

/// A rebindable keyboard shortcut that can be either a **key chord** (a key + modifiers,
/// e.g. ⌥Space) or a **bare-modifier chord** (modifiers only, e.g. left ⌥ or left ⌥+⌃),
/// with left/right-specific modifiers. Matched against the live held-modifier set tracked by
/// ``HotKeyTap``; persisted as JSON in `UserDefaults`.
struct Hotkey: Codable, Equatable, Sendable {
    /// Virtual key code (kVK_*); `nil` for a modifier-only chord.
    var keyCode: UInt16?
    /// The side-specific modifiers that must be held.
    var modifiers: Set<ModifierSide>
    /// Display name of the base key (empty for modifier-only chords).
    var keyLabel: String

    var isModifierOnly: Bool { keyCode == nil }

    // MARK: Defaults

    static let transcriptionDefault = Hotkey(keyCode: nil, modifiers: [.leftOption], keyLabel: "")
    static let askDefault = Hotkey(keyCode: nil, modifiers: [.leftOption, .leftControl], keyLabel: "")
    /// Continue-the-last-conversation Ask: the Ask chord plus left ⇧ (so it reads as "Ask, again").
    static let askContinueDefault = Hotkey(keyCode: nil, modifiers: [.leftOption, .leftControl, .leftShift], keyLabel: "")
    static let rewriteDefault = Hotkey(keyCode: nil, modifiers: [.leftOption, .leftShift], keyLabel: "")
    static let translateDefault = Hotkey(keyCode: nil, modifiers: [.leftControl, .leftShift], keyLabel: "")
    static let stopDefault = Hotkey(keyCode: UInt16(kVK_Escape), modifiers: [], keyLabel: "Esc")
    /// The radial mode picker's hold-trigger (default left ⌥). A bare-modifier chord so it reads as
    /// "hold a key"; when the picker is on it owns this chord and the per-mode chords stand down.
    static let radialDefault = Hotkey(keyCode: nil, modifiers: [.leftOption], keyLabel: "")

    // MARK: Matching

    /// A modifier-only chord matches when exactly its modifiers are held (exact equality, so
    /// ⌥ doesn't fire while ⌥⌃ is held — that's what keeps Transcription and Ask distinct).
    func matchesChord(heldSides: Set<ModifierSide>) -> Bool {
        keyCode == nil && heldSides == modifiers
    }

    /// A key chord matches when its key is pressed with exactly its modifiers held.
    func matchesKey(keyCode: UInt16, heldSides: Set<ModifierSide>) -> Bool {
        self.keyCode == keyCode && heldSides == modifiers
    }

    // MARK: Display

    /// One side-marked modifier: its glyph, an L/R marker, and a spelled-out name.
    private struct SideToken {
        let side: ModifierSide
        let glyph: String
        let marker: String
        let name: String
    }

    /// Side-marked tokens for each modifier, ordered control, option, shift, command, left before
    /// right within each -- the canonical order for both display forms.
    private static let sideTokens: [SideToken] = [
        SideToken(side: .leftControl, glyph: "⌃", marker: "L", name: "left control"),
        SideToken(side: .rightControl, glyph: "⌃", marker: "R", name: "right control"),
        SideToken(side: .leftOption, glyph: "⌥", marker: "L", name: "left option"),
        SideToken(side: .rightOption, glyph: "⌥", marker: "R", name: "right option"),
        SideToken(side: .leftShift, glyph: "⇧", marker: "L", name: "left shift"),
        SideToken(side: .rightShift, glyph: "⇧", marker: "R", name: "right shift"),
        SideToken(side: .leftCommand, glyph: "⌘", marker: "L", name: "left command"),
        SideToken(side: .rightCommand, glyph: "⌘", marker: "R", name: "right command")
    ]

    /// Human-readable form, side-aware: each held modifier renders as a side-marked glyph token, so
    /// left ⌥ ("L⌥") reads differently from right ⌥ ("R⌥"), and both appear when both sides are
    /// bound (e.g. "L⌥ + R⌥"). A key chord appends the key label. Compact enough for the recorder
    /// pill and HUD status lines.
    var display: String {
        var tokens = Self.sideTokens.filter { modifiers.contains($0.side) }.map { "\($0.marker)\($0.glyph)" }
        if !keyLabel.isEmpty { tokens.append(keyLabel) }
        return tokens.isEmpty ? "—" : tokens.joined(separator: " + ")
    }

    /// Spelled-out form for prose, e.g. "left option + right option" or "left control + Space".
    var verboseDisplay: String {
        var parts = Self.sideTokens.filter { modifiers.contains($0.side) }.map(\.name)
        if !keyLabel.isEmpty { parts.append(keyLabel) }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    /// The opposite-hand counterpart of a side-specific modifier (e.g. left ⌥ <-> right ⌥).
    static func pairedSide(of side: ModifierSide) -> ModifierSide {
        switch side {
        case .leftControl: return .rightControl
        case .rightControl: return .leftControl
        case .leftOption: return .rightOption
        case .rightOption: return .leftOption
        case .leftShift: return .rightShift
        case .rightShift: return .leftShift
        case .leftCommand: return .rightCommand
        case .rightCommand: return .leftCommand
        }
    }

    // MARK: Decoding side-specific modifiers from event flags

    /// Decode the held side-specific modifiers from a raw flags value — works for both
    /// `CGEventFlags.rawValue` (the global tap) and `NSEvent.modifierFlags.rawValue` (the
    /// recorder), which both carry the device-dependent `NX_DEVICE*` bits in their low bytes.
    /// If only the device-independent bit is set (some remappers/keyboards don't report a
    /// side), the modifier is assumed to be on the **left**.
    static func sides(rawFlags flags: UInt64) -> Set<ModifierSide> {
        var s: Set<ModifierSide> = []
        // Device-dependent bits (IOLLEvent.h NX_DEVICE*KEYMASK).
        if flags & 0x0000_0001 != 0 { s.insert(.leftControl) }
        if flags & 0x0000_2000 != 0 { s.insert(.rightControl) }
        if flags & 0x0000_0002 != 0 { s.insert(.leftShift) }
        if flags & 0x0000_0004 != 0 { s.insert(.rightShift) }
        if flags & 0x0000_0008 != 0 { s.insert(.leftCommand) }
        if flags & 0x0000_0010 != 0 { s.insert(.rightCommand) }
        if flags & 0x0000_0020 != 0 { s.insert(.leftOption) }
        if flags & 0x0000_0040 != 0 { s.insert(.rightOption) }

        // Device-independent presence → assume left when no side bit was reported.
        let di = NSEvent.ModifierFlags.self
        if flags & UInt64(di.control.rawValue) != 0, !s.contains(.leftControl), !s.contains(.rightControl) { s.insert(.leftControl) }
        if flags & UInt64(di.shift.rawValue) != 0, !s.contains(.leftShift), !s.contains(.rightShift) { s.insert(.leftShift) }
        if flags & UInt64(di.command.rawValue) != 0, !s.contains(.leftCommand), !s.contains(.rightCommand) { s.insert(.leftCommand) }
        if flags & UInt64(di.option.rawValue) != 0, !s.contains(.leftOption), !s.contains(.rightOption) { s.insert(.leftOption) }
        return s
    }

    // MARK: Key naming (for the recorder)

    static func label(for event: NSEvent) -> String {
        if let special = specialKeyNames[event.keyCode] { return special }
        if let chars = event.charactersIgnoringModifiers, let first = chars.first,
           first.isLetter || first.isNumber || first.isSymbol || first.isPunctuation {
            return chars.uppercased()
        }
        return "Key \(event.keyCode)"
    }

    private static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Return): "Return",
        UInt16(kVK_ANSI_KeypadEnter): "Enter",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Escape): "Esc",
        UInt16(kVK_Delete): "Delete",
        UInt16(kVK_ForwardDelete): "Fwd Del",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "Home",
        UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "Page Up",
        UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12"
    ]
}
