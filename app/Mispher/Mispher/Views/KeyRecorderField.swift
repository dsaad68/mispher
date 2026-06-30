import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A glass-pill control for rebinding a shortcut. Click it, then press a key chord (e.g.
/// ⌥Space) or — when `allowsModifierOnly` — a bare-modifier chord (e.g. left ⌥ or left ⌥+⌃);
/// it captures the result as a ``Hotkey``, left/right-aware. While recording it raises
/// `vm.isCapturingShortcut`, which stands the global engine down so the chord can be typed.
struct KeyRecorderField: View {
    @Environment(TranscriptionViewModel.self) private var vm
    let hotkey: Hotkey
    /// When false (the Stop field), only a real key is captured — Esc becomes a valid binding
    /// rather than a "cancel".
    var allowsModifierOnly: Bool = true
    let onChange: (Hotkey) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    /// The largest simultaneously-held modifier set seen during a modifier-only gesture.
    @State private var maxSides: Set<ModifierSide> = []

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: recording ? "circle.fill" : "keyboard")
                    .font(.system(size: recording ? 7 : 10, weight: .semibold))
                    .foregroundStyle(recording ? Palette.recRed : Palette.fg2)
                Text(recording ? "Press keys…" : hotkey.display)
                    .font(.sans(11.5, weight: .medium))
                    .foregroundStyle(recording ? Palette.fg : Palette.fg1)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .frame(minWidth: 84)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(recording ? Palette.accentSoft : .white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(recording ? Palette.accentGlow : Palette.border, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hold the pill at its intrinsic width so a tight row (next to the mode segmented) can't
        // squeeze it below the content and clip "Press keys…" -- the row's title wraps instead.
        .fixedSize()
        .help(
            recording
                ? (allowsModifierOnly ? "Press the keys to use (Esc cancels)" : "Press the keys to use")
                : "Click, then press a new shortcut"
        )
        .onDisappear { stopRecording() }
    }

    private func toggle() {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        recording = true
        maxSides = []
        vm.isCapturingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .keyDown:
                let bareEsc = event.keyCode == UInt16(kVK_Escape)
                    && event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask)
                // Esc cancels the talk recorders; for the Stop field it's a valid key.
                if bareEsc, allowsModifierOnly { stopRecording(); return nil }
                let sides = Hotkey.sides(rawFlags: UInt64(event.modifierFlags.rawValue))
                onChange(Hotkey(keyCode: event.keyCode, modifiers: sides, keyLabel: Hotkey.label(for: event)))
                stopRecording()
                return nil
            case .flagsChanged:
                let sides = Hotkey.sides(rawFlags: UInt64(event.modifierFlags.rawValue))
                if sides.isEmpty {
                    // Released everything: capture the peak chord as a modifier-only shortcut.
                    if allowsModifierOnly, !maxSides.isEmpty {
                        onChange(Hotkey(keyCode: nil, modifiers: maxSides, keyLabel: ""))
                        stopRecording()
                    }
                } else if sides.count > maxSides.count {
                    maxSides = sides
                }
                return nil
            default:
                return event
            }
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        maxSides = []
        vm.isCapturingShortcut = false
    }
}
