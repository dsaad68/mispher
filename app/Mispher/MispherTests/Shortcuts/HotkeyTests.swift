import AppKit
import Carbon.HIToolbox
import Foundation
@testable import Mispher
import Testing

/// The side-aware ``Hotkey`` model: decoding left/right modifiers from raw event flags, exact-match
/// chord/key matching, the side-marked display strings, and Codable round-tripping.
struct HotkeyTests {
    // MARK: sides(rawFlags:)

    @Test func decodesEachDeviceDependentSideBit() {
        #expect(Hotkey.sides(rawFlags: 0x0000_0001) == [.leftControl])
        #expect(Hotkey.sides(rawFlags: 0x0000_2000) == [.rightControl])
        #expect(Hotkey.sides(rawFlags: 0x0000_0002) == [.leftShift])
        #expect(Hotkey.sides(rawFlags: 0x0000_0004) == [.rightShift])
        #expect(Hotkey.sides(rawFlags: 0x0000_0008) == [.leftCommand])
        #expect(Hotkey.sides(rawFlags: 0x0000_0010) == [.rightCommand])
        #expect(Hotkey.sides(rawFlags: 0x0000_0020) == [.leftOption])
        #expect(Hotkey.sides(rawFlags: 0x0000_0040) == [.rightOption])
    }

    @Test func decodesBothSidesOfTheSameModifier() {
        // Right option + left option held together.
        #expect(Hotkey.sides(rawFlags: 0x0000_0020 | 0x0000_0040) == [.leftOption, .rightOption])
    }

    @Test func deviceIndependentOnlyAssumesLeft() {
        // The device-independent option mask with no side bit → assume left.
        let flags = UInt64(NSEvent.ModifierFlags.option.rawValue)
        #expect(Hotkey.sides(rawFlags: flags) == [.leftOption])
    }

    // MARK: matching

    @Test func modifierChordMatchesExactly() {
        #expect(Hotkey.transcriptionDefault.matchesChord(heldSides: [.leftOption]))
        // ⌥ must not fire while ⌥⌃ is held (exact equality keeps Transcription vs Ask distinct).
        #expect(!Hotkey.transcriptionDefault.matchesChord(heldSides: [.leftOption, .leftControl]))
        #expect(Hotkey.askDefault.matchesChord(heldSides: [.leftOption, .leftControl]))
        #expect(!Hotkey.askDefault.matchesChord(heldSides: [.leftOption]))
    }

    @Test func bothSidesChordRequiresBothSides() {
        let chord = Hotkey(keyCode: nil, modifiers: [.leftOption, .rightOption], keyLabel: "")
        #expect(chord.matchesChord(heldSides: [.leftOption, .rightOption]))
        #expect(!chord.matchesChord(heldSides: [.leftOption]))
        #expect(!chord.matchesChord(heldSides: [.rightOption]))
    }

    @Test func keyChordMatchesKeyAndModifiers() {
        #expect(Hotkey.stopDefault.matchesKey(keyCode: UInt16(kVK_Escape), heldSides: []))
        #expect(!Hotkey.stopDefault.matchesKey(keyCode: UInt16(kVK_Escape), heldSides: [.leftCommand]))
        let chord = Hotkey(keyCode: UInt16(kVK_Space), modifiers: [.leftOption], keyLabel: "Space")
        #expect(chord.matchesKey(keyCode: UInt16(kVK_Space), heldSides: [.leftOption]))
        #expect(!chord.matchesKey(keyCode: UInt16(kVK_Space), heldSides: []))
    }

    // MARK: display

    @Test func displayMarksSides() {
        #expect(Hotkey(keyCode: nil, modifiers: [.leftOption], keyLabel: "").display == "L⌥")
        #expect(Hotkey(keyCode: nil, modifiers: [.rightOption], keyLabel: "").display == "R⌥")
        #expect(Hotkey(keyCode: nil, modifiers: [.leftOption, .rightOption], keyLabel: "").display == "L⌥ + R⌥")
    }

    @Test func displayOrdersControlOptionShiftCommandThenKey() {
        // Ask default is left ⌥ + left ⌃ → control comes before option.
        #expect(Hotkey.askDefault.display == "L⌃ + L⌥")
        let chord = Hotkey(keyCode: UInt16(kVK_Space), modifiers: [.leftOption], keyLabel: "Space")
        #expect(chord.display == "L⌥ + Space")
    }

    @Test func emptyHotkeyDisplaysDash() {
        #expect(Hotkey(keyCode: nil, modifiers: [], keyLabel: "").display == "—")
    }

    @Test func verboseDisplaySpellsOutSides() {
        let chord = Hotkey(keyCode: nil, modifiers: [.rightOption, .leftOption], keyLabel: "")
        #expect(chord.verboseDisplay == "left option + right option")
        #expect(Hotkey.stopDefault.verboseDisplay == "Esc")
    }

    @Test func pairedSideIsOppositeHand() {
        #expect(Hotkey.pairedSide(of: .leftOption) == .rightOption)
        #expect(Hotkey.pairedSide(of: .rightCommand) == .leftCommand)
        #expect(Hotkey.pairedSide(of: .leftShift) == .rightShift)
        #expect(Hotkey.pairedSide(of: .rightControl) == .leftControl)
    }

    // MARK: Codable

    @Test func codableRoundTripPreservesSides() throws {
        let original = Hotkey(keyCode: UInt16(kVK_Space), modifiers: [.leftOption, .rightOption, .leftShift], keyLabel: "Space")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: data)
        #expect(decoded == original)
    }
}
