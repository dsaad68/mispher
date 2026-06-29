import Foundation

/// Single source of truth for the recording lifecycle.
/// idle → preparing → recording ⇄ paused → finalizing → idle, with `error`
/// reachable from any step (mic denied, model load failure, server unreachable).
/// `paused` keeps the engine session alive so recording can continue; only
/// `stop` (→ finalizing) ends it.
enum RecordingState: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case finalizing
    case error(String)
}
