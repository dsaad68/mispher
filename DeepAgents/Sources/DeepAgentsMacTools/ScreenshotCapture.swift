import AppKit
import CoreGraphics
import DeepAgents
import Foundation
import ScreenCaptureKit

/// Captures the screen or the frontmost window with ScreenCaptureKit and writes the result
/// to a temporary PNG. Kept free of agent/UI types so it can be reasoned about on its own
/// (the way `ArithmeticEvaluator` isolates arithmetic).
///
/// Needs the Screen Recording permission (System Settings ▸ Privacy & Security ▸ Screen
/// Recording); the first capture triggers the system prompt and the app usually has to be
/// relaunched after the grant. The app is not sandboxed, so no entitlement is required.
public enum ScreenshotCapture {
    /// A capture failure carrying a user-facing explanation the agent can relay verbatim.
    public struct CaptureError: Error {
        public let message: String
        public init(message: String) { self.message = message }
    }

    /// One captured window: the PNG file URL, the human-facing window name ("App — Title"),
    /// and the captured pixel size.
    public struct WindowCapture: Sendable {
        public let url: URL
        public let window: String
        public let size: CGSize

        public init(url: URL, window: String, size: CGSize) {
            self.url = url
            self.window = window
            self.size = size
        }
    }

    /// Capture the main display (`fullScreen`) or the frontmost window, always excluding
    /// Mispher's own windows so the HUD isn't in the shot. Returns the PNG file URL and the
    /// captured pixel size.
    static func capture(fullScreen: Bool) async throws -> (url: URL, size: CGSize) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError(message:
                "I need Screen Recording permission to do that. Open System Settings ▸ Privacy "
                    + "& Security ▸ Screen Recording, enable Mispher, then relaunch the app and ask "
                    + "again.")
        }

        // Identify our own app so its windows never end up in the capture. Match by process
        // id first (works even when launched as a bare executable with no bundle identity),
        // and by bundle id as a backstop.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        func isOwn(_ app: SCRunningApplication) -> Bool {
            app.processID == ownPID || (ownBundleID != nil && app.bundleIdentifier == ownBundleID)
        }

        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        config.showsCursor = false

        if fullScreen {
            guard let display = content.displays.first else {
                throw CaptureError(message: "I couldn't find a display to capture.")
            }
            let ownApps = content.applications.filter(isOwn)
            filter = SCContentFilter(
                display: display, excludingApplications: ownApps, exceptingWindows: []
            )
            config.width = display.width
            config.height = display.height
        } else {
            // `content.windows` is front-to-back, so the first match is the frontmost. Layer 0
            // skips the menu bar, Dock, and overlay windows; the area floor skips tiny tool /
            // status windows.
            guard let window = content.windows.first(where: { window in
                guard let app = window.owningApplication, !isOwn(app) else { return false }
                return window.isOnScreen
                    && window.windowLayer == 0
                    && window.frame.width * window.frame.height > 5000
            }) else {
                throw CaptureError(message:
                    "I don't see another app window in front to capture. Bring the window you "
                        + "want me to look at to the front and ask again.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
        }

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            throw CaptureError(message:
                "The screenshot capture failed (\(error.localizedDescription)).")
        }

        let url = try writePNG(image)
        return (url, CGSize(width: image.width, height: image.height))
    }

    /// Capture every eligible on-screen window separately, writing one PNG per window into a
    /// single per-invocation temp subfolder, and return one entry per window. Uses the same
    /// filtering as the single-window path (excludes Mispher's own windows, the menu bar,
    /// Dock, overlays, and tiny tool/status windows) so the list is the "real" app windows.
    /// Windows are returned front-to-back; a window that fails to capture is skipped rather
    /// than failing the whole batch.
    static func captureWindows() async throws -> [WindowCapture] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError(message:
                "I need Screen Recording permission to do that. Open System Settings ▸ Privacy "
                    + "& Security ▸ Screen Recording, enable Mispher, then relaunch the app and ask "
                    + "again.")
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        func isOwn(_ app: SCRunningApplication) -> Bool {
            app.processID == ownPID || (ownBundleID != nil && app.bundleIdentifier == ownBundleID)
        }

        // `content.windows` is front-to-back; keep the order so index 0 is the frontmost.
        let windows = content.windows.filter { window in
            guard let app = window.owningApplication, !isOwn(app) else { return false }
            return window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width * window.frame.height > 5000
        }
        guard !windows.isEmpty else {
            throw CaptureError(message:
                "I don't see any app windows to capture. Open the windows you want me to look "
                    + "at and ask again.")
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-windows-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw CaptureError(message:
                "I couldn't create a folder to save the window screenshots.")
        }

        var captures: [WindowCapture] = []
        for window in windows {
            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: config
                )
            } catch {
                continue // skip a window that won't capture; keep the rest
            }
            let name = displayName(for: window)
            // Number filenames by 1-based position in the *captured* list (not the original window
            // index), so skipped windows leave no gaps and a file's number matches its 1-based entry
            // in the manifest the planner sees.
            let url = folder.appendingPathComponent(fileName(for: name, index: captures.count + 1))
            guard let savedURL = try? writePNG(image, to: url) else { continue }
            captures.append(
                WindowCapture(
                    url: savedURL, window: name,
                    size: CGSize(width: image.width, height: image.height)
                )
            )
        }
        guard !captures.isEmpty else {
            throw CaptureError(message: "I couldn't capture any of the open windows.")
        }
        return captures
    }

    /// "App — Title", falling back to just the app name when the window has no title (window
    /// titles are frequently empty).
    private static func displayName(for window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Unknown App"
        let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? app : "\(app) — \(title)"
    }

    /// A filesystem-safe PNG name derived from a window's display name, prefixed with the
    /// window's index so two identically named windows never collide. The slug is capped well under
    /// the filesystem's per-component byte limit (commonly 255) so a long window title can't produce
    /// a name `writePNG` fails to create, silently dropping that capture.
    private static func fileName(for name: String, index: Int) -> String {
        let allowed = CharacterSet.alphanumerics
        var slug = String(String.UnicodeScalarView(name.unicodeScalars.map {
            allowed.contains($0) ? $0 : "-"
        }))
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        slug = truncated(slug, toUTF8Bytes: 200)
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")) // in case truncation cut at a "-"
        if slug.isEmpty { slug = "window" }
        return "\(index)-\(slug).png"
    }

    /// Truncate `string` to at most `maxBytes` UTF-8 bytes on a scalar boundary (never splitting a
    /// character), so the resulting filename component stays within the filesystem's byte limit.
    private static func truncated(_ string: String, toUTF8Bytes maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        for scalar in string.unicodeScalars {
            let width = String(scalar).utf8.count
            if bytes + width > maxBytes { break }
            bytes += width
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Encode a `CGImage` as PNG into a unique temp file and return its URL.
    private static func writePNG(_ image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mispher-shot-\(UUID().uuidString).png")
        return try writePNG(image, to: url)
    }

    /// Encode a `CGImage` as PNG and write it to `url`, returning that URL.
    private static func writePNG(_ image: CGImage, to url: URL) throws -> URL {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError(message: "I couldn't encode the screenshot.")
        }
        do {
            try data.write(to: url)
        } catch {
            throw CaptureError(message: "I couldn't save the screenshot to disk.")
        }
        return url
    }
}

/// The source the screenshot tools capture from. Abstracting it lets the in-app tools run on
/// the real ``LiveScreenCapture`` while the headless scenario harness substitutes a
/// `FixtureScreenCapture` that returns pre-baked PNGs — so screen-dependent scenarios are
/// deterministic and need no Screen Recording permission.
public protocol ScreenCaptureProviding: Sendable {
    /// Capture the whole display (`fullScreen`) or the frontmost window. Returns the PNG file
    /// URL and the captured pixel size.
    func capture(fullScreen: Bool) async throws -> (url: URL, size: CGSize)
    /// Capture every eligible open window separately, front-to-back (one entry per window).
    func captureWindows() async throws -> [ScreenshotCapture.WindowCapture]
}

/// The production capture provider: forwards to ``ScreenshotCapture``'s ScreenCaptureKit
/// implementation. Stateless, so a single shared instance is fine.
struct LiveScreenCapture: ScreenCaptureProviding {
    func capture(fullScreen: Bool) async throws -> (url: URL, size: CGSize) {
        try await ScreenshotCapture.capture(fullScreen: fullScreen)
    }

    func captureWindows() async throws -> [ScreenshotCapture.WindowCapture] {
        try await ScreenshotCapture.captureWindows()
    }
}
