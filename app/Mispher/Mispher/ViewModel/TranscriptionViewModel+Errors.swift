import Foundation

/// Error-formatting helper, split out of ``TranscriptionViewModel`` to keep the main file within
/// the length limit. Internal (not `private`) so the main file's `Self.describe(error)` call sites
/// still resolve across the file boundary.
extension TranscriptionViewModel {
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
