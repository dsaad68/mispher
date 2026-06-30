import DeepAgentsMLX
import Foundation

/// The recording-status line shown in the HUD while a session is live. Split out of
/// ``TranscriptionViewModel`` so the main file stays within the length limit; the copy is
/// tailored to the active intent (transcription, ask, rewrite) and its activation mode.
@MainActor
extension TranscriptionViewModel {
    /// Whether the Ask presentation can host the multi-turn overlay. All non-main styles qualify:
    /// floating notch and floating card host ``FloatingAskView``; Dynamic Island hosts the notch.
    var askOverlaySupported: Bool { askPresentation != .mainWindow }

    /// The text the Copy control acts on: the live transcript during a session, otherwise the final text.
    var transcriptForCopy: String { isSessionActive ? partialText : finalText }

    var hasCopyableText: Bool { !transcriptForCopy.isEmpty }

    /// Status line while recording, tailored to the active intent and its mode.
    var recordingStatus: String {
        let stopHint = stopShortcut.display
        switch activeRawIntent {
        case .ask, .askContinue:
            // A continue session shows its own mode + chord; a fresh Ask shows Ask's.
            let isContinue = activeRawIntent == .askContinue
            let key = (isContinue ? askContinueShortcut : askShortcut).display
            switch isContinue ? askContinueMode : askMode {
            case .hold: return "Recording - release \(key) to answer."
            case .trigger: return "Recording - tap \(key) or \(stopHint) to answer."
            case .holdRelease: return "Recording - long-press \(key) again or \(stopHint) to answer."
            }
        case .transcription:
            switch transcriptionMode {
            case .hold:
                let finish = transcriptionFinishBehavior == .stop ? "stop" : "pause"
                return "Recording - release \(transcriptionShortcut.display) to \(finish) · \(stopHint) to stop."
            case .trigger: return "Recording - tap \(transcriptionShortcut.display) or \(stopHint) to stop."
            case .holdRelease: return "Recording - long-press \(transcriptionShortcut.display) again or \(stopHint) to stop."
            }
        case .rewrite:
            switch rewriteMode {
            case .hold: return "Recording - release \(rewriteShortcut.display) to rewrite the selection."
            case .trigger: return "Recording - tap \(rewriteShortcut.display) or \(stopHint) to rewrite."
            case .holdRelease: return "Recording - long-press \(rewriteShortcut.display) again to rewrite the selection."
            }
        case .translate:
            let lang = translationTargetLanguage.displayName
            switch translateMode {
            case .hold: return "Recording - release \(translateShortcut.display) to translate to \(lang)."
            case .trigger: return "Recording - tap \(translateShortcut.display) or \(stopHint) to translate."
            case .holdRelease: return "Recording - long-press \(translateShortcut.display) again or \(stopHint) to translate to \(lang)."
            }
        }
    }
}
