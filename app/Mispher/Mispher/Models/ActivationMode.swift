import Foundation

/// How a talk shortcut activates:
/// - **hold** (Push to talk): record while the chord/key is held; releasing ends the segment.
///   An optional global start delay (``TranscriptionViewModel/pushToTalkStartDelay``) requires the
///   key be held that long before recording begins.
/// - **trigger**: tap once to start, tap again to stop.
/// - **holdRelease** (Hold & release): a long-press to *toggle on* -- hold the chord/key for
///   ``TranscriptionViewModel/holdReleaseDuration`` and recording starts and keeps going after you
///   let go. Being hands-free, it always ends on the silence timeout (or a second long-press / the
///   Stop shortcut) -- see ``TranscriptionViewModel/shouldArmSilence(enabled:mode:)``.
///
/// Trigger can *also* auto-finish after a pause in speech when
/// ``TranscriptionViewModel/silenceAutoEndEnabled`` is on (replacing the old standalone hands-free
/// mode); Hold & release does so unconditionally. The `hold`/`trigger` raw values are kept stable
/// for back-compat; a legacy `"handsFree"` value is migrated to `.trigger` on load (see
/// `TranscriptionViewModel.loadMode`).
enum ActivationMode: String, Codable, CaseIterable, Sendable, Hashable {
    case hold, trigger, holdRelease
}

/// What happens to a **transcription** when its manual finish gesture fires (push-to-talk release,
/// trigger second tap, or hold-and-release second long-press): `pause` keeps the text and waits for
/// the Stop shortcut/button to drop it into the field; `stop` commits it immediately. The silence
/// auto-end always commits regardless of this setting.
enum TranscriptionFinishBehavior: String, Codable, CaseIterable, Sendable, Hashable {
    case pause, stop
}

/// What a recording session is for -- set by *which* shortcut started it, replacing the old
/// "is an Ask model selected?" mode switch. On finalize, `ask` sends the transcript to the
/// model; `transcription` just keeps the text (and translates it when translation is on);
/// `rewrite` applies the spoken instruction to the text selected in the frontmost app and
/// writes the result back in place; `translate` translates the transcript into the target
/// language and inserts it into the focused field.
enum RecordIntent: String, Sendable, Hashable {
    case transcription, ask, rewrite, translate
    /// A second Ask binding: the same flow as `.ask`, but it *continues* the last conversation
    /// instead of starting a fresh one. It only exists at the shortcut layer - everything downstream
    /// collapses it to `.ask` via ``asActiveIntent``.
    case askContinue
}

extension RecordIntent {
    /// The intent that drives session state. The two Ask shortcuts (`.ask` = new conversation,
    /// `.askContinue` = follow-up) differ only in whether they clear the thread first, so
    /// `activeIntent`, the activation mode, finalize, and the status line all treat them identically.
    var asActiveIntent: RecordIntent { self == .askContinue ? .ask : self }
}
