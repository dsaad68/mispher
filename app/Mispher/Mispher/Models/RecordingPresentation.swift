import Foundation

/// How the live transcript is presented while a dictation session is active: the full HUD
/// window, a pill floating under the notch, a small draggable panel, or a Dynamic Island that
/// grows out of the notch. The compact styles show only while recording and disappear once the
/// text is inserted, so dictation into another app stays out of the way (the large HUD never has
/// to pop up).
enum RecordingPresentation: String, Codable, CaseIterable, Sendable, Hashable {
    case mainWindow
    /// A pill that floats just under the notch. Stored as `"notch"` so the setting survives the
    /// rename from the original "Notch" mode.
    case floatingNotch = "notch"
    case floating
    /// A Dynamic Island that grows out of the notch while recording and collapses back when the
    /// session ends.
    case dynamicIsland

    /// Short label for the Settings picker.
    var label: String {
        switch self {
        case .mainWindow: return "Main"
        case .floatingNotch: return "Floating notch"
        case .floating: return "Floating"
        case .dynamicIsland: return "Dynamic Island"
        }
    }

    /// One-line description shown beside the label in the Settings picker.
    var detail: String {
        switch self {
        case .mainWindow: return "Use the main app window."
        case .floatingNotch: return "A pill under the notch."
        case .floating: return "A small draggable panel."
        case .dynamicIsland: return "Expands out of the notch."
        }
    }

    /// SF Symbol shown next to the option in the Settings picker.
    var systemImage: String {
        switch self {
        case .mainWindow: return "macwindow"
        case .floatingNotch: return "rectangle.topthird.inset.filled"
        case .floating: return "macwindow.on.rectangle"
        case .dynamicIsland: return "capsule.fill"
        }
    }
}
