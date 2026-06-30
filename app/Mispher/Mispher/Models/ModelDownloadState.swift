import Foundation

/// Per-model download status, observed by the Settings model manager and the
/// header dropdown (which only lets you activate `.downloaded` models).
enum ModelDownloadState: Equatable, Sendable {
    /// Not yet checked against disk.
    case unknown
    /// Confirmed absent — offer a Download button.
    case notDownloaded
    /// Download in progress, with fractional progress in `0...1`.
    case downloading(Double)
    /// Present on disk (or, for Qwen, server-based and always available).
    case downloaded
    /// Last download attempt failed, with a short reason.
    case failed(String)

    var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}
