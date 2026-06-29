import CoreText
import Foundation
import os

/// Registers the app's bundled custom fonts (Satoshi, Sentient, Hedvig Letters Serif, Instrument Serif, Fira Code)
/// with CoreText at launch so `Font.custom(...)` can resolve them by PostScript name. The font
/// files live in `Fonts/` and are copied into the bundle automatically by Xcode's synchronized
/// group, so we discover them at runtime rather than hard-coding a manifest.
enum AppFonts {
    private static let log = Logger(subsystem: "verybadcompany.Mispher", category: "fonts")

    /// Register every bundled `.otf` / `.ttf`. Idempotent: re-registering an already-registered
    /// font is treated as success. Call once, before any view renders.
    static func register() {
        let urls = Set(["otf", "ttf"].flatMap { ext in
            (Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? [])
                + (Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
        })

        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // `kCTFontManagerErrorAlreadyRegistered` (105) just means a prior launch path
                // already registered it -- harmless. Log anything else.
                let code = (error?.takeRetainedValue() as Error?).map { ($0 as NSError).code } ?? -1
                if code != 105 {
                    log.error("Failed to register font \(url.lastPathComponent, privacy: .public) (code \(code))")
                }
            }
        }
    }
}
