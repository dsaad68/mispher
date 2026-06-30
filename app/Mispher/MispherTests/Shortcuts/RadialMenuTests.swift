import Carbon.HIToolbox
import Foundation
@testable import Mispher
import Testing

/// The pure radial-picker core: pointer-offset → direction math (with the dead-zone and the pinned
/// 45° boundaries), arrow-key mapping, and the locked wheel layout.
struct RadialMenuTests {
    // MARK: direction from a pointer offset (AppKit y-up)

    @Test func cardinalDirectionsFromOffset() {
        let deadZone: CGFloat = 30
        #expect(RadialDirection.from(dx: 0, dy: 60, deadZone: deadZone) == .up)
        #expect(RadialDirection.from(dx: 60, dy: 0, deadZone: deadZone) == .right)
        #expect(RadialDirection.from(dx: 0, dy: -60, deadZone: deadZone) == .down)
        #expect(RadialDirection.from(dx: -60, dy: 0, deadZone: deadZone) == .left)
    }

    @Test func deadZoneReturnsNil() {
        #expect(RadialDirection.from(dx: 0, dy: 0, deadZone: 30) == nil)
        #expect(RadialDirection.from(dx: 10, dy: 10, deadZone: 30) == nil) // hypot ~14 < 30
        // Just past the dead-zone resolves again.
        #expect(RadialDirection.from(dx: 0, dy: 31, deadZone: 30) == .up)
    }

    @Test func diagonalBoundariesArePinned() {
        let deadZone: CGFloat = 10
        // +45° (dx == dy > 0): right owns the (-45°, 45°] closing edge.
        #expect(RadialDirection.from(dx: 40, dy: 40, deadZone: deadZone) == .right)
        // +135° (-dx == dy): up owns (45°, 135°].
        #expect(RadialDirection.from(dx: -40, dy: 40, deadZone: deadZone) == .up)
        // -45° (dx == -dy): down owns (-135°, -45°].
        #expect(RadialDirection.from(dx: 40, dy: -40, deadZone: deadZone) == .down)
        // -135°: left.
        #expect(RadialDirection.from(dx: -40, dy: -40, deadZone: deadZone) == .left)
    }

    // MARK: arrow keys

    @Test func arrowKeyCodesMapToDirections() {
        #expect(RadialDirection.from(arrowKeyCode: UInt16(kVK_UpArrow)) == .up)
        #expect(RadialDirection.from(arrowKeyCode: UInt16(kVK_DownArrow)) == .down)
        #expect(RadialDirection.from(arrowKeyCode: UInt16(kVK_LeftArrow)) == .left)
        #expect(RadialDirection.from(arrowKeyCode: UInt16(kVK_RightArrow)) == .right)
        #expect(RadialDirection.from(arrowKeyCode: UInt16(kVK_Space)) == nil)
    }

    // MARK: layout (default + editing)

    @Test func defaultLayoutMapsDirectionsToModes() {
        let layout = RadialLayout.default
        #expect(layout.mode(at: .up) == .transcription)
        #expect(layout.mode(at: .right) == .translate)
        #expect(layout.mode(at: .down) == .rewrite)
        #expect(layout.mode(at: .left) == .ask)
    }

    @Test func radialModesCoverTheFourWheelIntents() {
        #expect(Set(RadialMode.allCases.map(\.intent)) == [.transcription, .translate, .rewrite, .ask])
    }

    @Test func assigningSwapsToKeepABijection() {
        // Move Ask (left) onto Up: Up's old mode (Transcribe) lands in Ask's old slot (left).
        let swapped = RadialLayout.default.assigning(.ask, to: .up)
        #expect(swapped.mode(at: .up) == .ask)
        #expect(swapped.mode(at: .left) == .transcription)
        // Untouched slots stay put, and all four modes remain present exactly once.
        #expect(swapped.mode(at: .right) == .translate)
        #expect(swapped.mode(at: .down) == .rewrite)
        #expect(Set(RadialLayout.order.map(swapped.mode(at:))) == Set(RadialMode.allCases))
    }

    @Test func assigningTheSameModeIsANoOp() {
        #expect(RadialLayout.default.assigning(.transcription, to: .up) == .default)
    }

    @Test func layoutPersistenceRoundTrips() {
        let edited = RadialLayout.default.assigning(.ask, to: .up)
        #expect(RadialLayout(rawValues: edited.rawValues) == edited)
    }

    @Test func layoutRejectsCorruptRawValues() {
        #expect(RadialLayout(rawValues: ["ask", "ask", "rewrite", "translate"]) == nil) // dup + missing
        #expect(RadialLayout(rawValues: ["ask", "translate"]) == nil) // too few
        #expect(RadialLayout(rawValues: ["bogus", "translate", "rewrite", "ask"]) == nil) // invalid value
    }

    // MARK: Ask slice New / Continue split

    @Test func askChoiceIntentsMapToFreshAndContinue() {
        #expect(RadialAskChoice.new.intent == .ask)
        #expect(RadialAskChoice.resume.intent == .askContinue)
    }

    @Test func askChoiceSplitsTheLeftWedgeByAim() {
        // Default layout puts Ask on the left (mid 180° in SwiftUI screen angle): the New label sits in
        // the upper-left half, Continue in the lower-left half (AppKit y-up offsets from the center).
        #expect(RadialAskChoice.from(dx: -40, dy: 20, wedge: .left) == .new) // upper-left
        #expect(RadialAskChoice.from(dx: -40, dy: -20, wedge: .left) == .resume) // lower-left
    }

    @Test func askChoiceSplitIsOrientationIndependent() {
        // Wherever Ask is mapped, the half toward the wedge's `mid + 45°` edge is New, the other Continue.
        #expect(RadialAskChoice.from(dx: 40, dy: -20, wedge: .right) == .new) // lower-right
        #expect(RadialAskChoice.from(dx: 40, dy: 20, wedge: .right) == .resume) // upper-right
        #expect(RadialAskChoice.from(dx: 20, dy: 40, wedge: .up) == .new) // up-right
        #expect(RadialAskChoice.from(dx: -20, dy: 40, wedge: .up) == .resume) // up-left
    }

    @Test func askChoiceCenterAimIsNew() {
        // Pointing straight down the wedge's center line resolves to New (the primary action).
        #expect(RadialAskChoice.from(dx: -40, dy: 0, wedge: .left) == .new) // straight left
        #expect(RadialAskChoice.from(dx: 0, dy: 40, wedge: .up) == .new) // straight up
    }

    @Test func radialDefaultTriggerIsLeftOption() {
        #expect(Hotkey.radialDefault == Hotkey(keyCode: nil, modifiers: [.leftOption], keyLabel: ""))
        #expect(Hotkey.radialDefault.isModifierOnly)
    }
}
