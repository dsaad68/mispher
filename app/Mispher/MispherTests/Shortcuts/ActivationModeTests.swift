import Foundation
@testable import Mispher
import Testing

/// The activation-mode and finish-behavior enums: stable raw values (so persisted settings survive
/// the rename) and exactly three modes after removing the old hands-free case.
struct ActivationModeTests {
    @Test func rawValuesAreStable() {
        #expect(ActivationMode.hold.rawValue == "hold")
        #expect(ActivationMode.trigger.rawValue == "trigger")
        #expect(ActivationMode.holdRelease.rawValue == "holdRelease")
    }

    @Test func exactlyThreeModes() {
        #expect(ActivationMode.allCases.count == 3)
        #expect(ActivationMode(rawValue: "handsFree") == nil) // removed
    }

    @Test func activationModeCodableRoundTrips() throws {
        for mode in ActivationMode.allCases {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(ActivationMode.self, from: data) == mode)
        }
    }

    @Test func finishBehaviorRawValuesAndRoundTrip() throws {
        #expect(TranscriptionFinishBehavior.pause.rawValue == "pause")
        #expect(TranscriptionFinishBehavior.stop.rawValue == "stop")
        for behavior in TranscriptionFinishBehavior.allCases {
            let data = try JSONEncoder().encode(behavior)
            #expect(try JSONDecoder().decode(TranscriptionFinishBehavior.self, from: data) == behavior)
        }
    }
}
