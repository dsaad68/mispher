import Foundation

/// User-facing errors with actionable guidance.
enum AppError: LocalizedError {
    case micPermissionDenied
    case micUnavailable
    case modelLoadFailed(String)
    case modelDownloadFailed(String)
    case serverUnreachable
    case serverHTTP(Int)
    case serverBinaryMissing
    case serverLaunchFailed(String)
    case audioEncodingFailed

    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "Microphone permission denied. Enable it in System Settings ▸ Privacy & Security ▸ Microphone."
        case .micUnavailable:
            return "No microphone input is available."
        case .modelLoadFailed(let detail):
            return "Model load failed: \(detail)"
        case .modelDownloadFailed(let detail):
            return "Model download failed: \(detail)"
        case .serverUnreachable:
            return "Local server not reachable. Make sure llama.cpp is installed and reachable."
        case .serverHTTP(let code):
            return "Local server returned HTTP \(code)."
        case .serverBinaryMissing:
            return "Couldn't find llama-server. Install llama.cpp (e.g. 'brew install llama.cpp') and try again."
        case .serverLaunchFailed(let role):
            return "Couldn't start the \(role). Check that llama.cpp is installed and the model can be downloaded."
        case .audioEncodingFailed:
            return "Failed to encode or resample the captured audio."
        }
    }
}
