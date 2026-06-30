import SwiftUI

/// Design tokens ported from the Liuli HUD prototype (dark glassmorphic theme,
/// cyan accent). Centralized here so every view shares one visual language.
enum Palette {
    // Wallpaper / background
    static let bgDeep = Color(red: 0.063, green: 0.075, blue: 0.090)
    static let wallpaperA = Color(red: 0.115, green: 0.130, blue: 0.165)
    static let wallpaperB = Color(red: 0.050, green: 0.060, blue: 0.082)
    static let wallpaperC = Color(red: 0.070, green: 0.102, blue: 0.124)

    // Glass surfaces
    static let glassFill = Color(red: 0.086, green: 0.102, blue: 0.129)

    // Accent (oklch(0.82 0.12 200) ≈ soft cyan)
    static let accent = Color(red: 0.45, green: 0.84, blue: 0.91)
    static var accentSoft: Color { accent.opacity(0.16) }
    static var accentGlow: Color { accent.opacity(0.35) }

    // Semantic
    static let warm = Color(red: 0.93, green: 0.66, blue: 0.40)
    static let recRed = Color(red: 1.0, green: 0.35, blue: 0.35)
    static let success = Color(red: 0.25, green: 0.82, blue: 0.60)

    // Foreground ramp (white at descending alpha)
    static var fg: Color { .white.opacity(0.94) }
    static var fg1: Color { .white.opacity(0.72) }
    static var fg2: Color { .white.opacity(0.50) }
    static var fg3: Color { .white.opacity(0.32) }

    // Hairlines
    static var border: Color { .white.opacity(0.08) }
    static var borderStrong: Color { .white.opacity(0.14) }
}

/// The app's four typeface roles and the `Font.Weight` -> bundled-face mapping for each.
/// Custom fonts do not synthesize weights, so every weight maps to a concrete PostScript face
/// (see `FontRegistrar`). Keeping the mapping here means the whole type system -- and choices
/// like "Satoshi has no semibold, so map it to Bold" -- is tunable in one place.
enum Typeface {
    /// Family names for MarkdownUI, which resolves bold/italic *within* a family rather than by
    /// an explicit face name. `serifFamily` is used for agent **messages**; `sansFamily` for agent
    /// **thinking** (and any sans markdown body).
    ///
    /// Sentient ExtraLight is the agent message reading face. We bundle only the ExtraLight +
    /// ExtraLight Italic faces, so emphasis resolves to the true italic while strong synthesizes a
    /// faux-bold (there is no ExtraLight bold) -- same behaviour as the previous single-face serif.
    static let serifFamily = "Sentient Extralight"
    static let sansFamily = "Satoshi"
    static let monoFamily = "Fira Code"

    /// Satoshi (sans UI text, dictation/transcript, agent thinking). Has Light/Regular/Medium/Bold/
    /// Black but **no semibold (600)**, so `.semibold` maps to Bold to keep it distinct from `.medium`.
    static func sans(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: "Satoshi-Light"
        case .medium: "Satoshi-Medium"
        case .semibold, .bold: "Satoshi-Bold"
        case .heavy, .black: "Satoshi-Black"
        default: "Satoshi-Regular"
        }
    }

    /// Instrument Serif (app name + prominent titles). Ships a single Regular face, so weight is
    /// ignored; markdown isn't rendered in it, so no bold/italic faces are needed.
    static func title(_: Font.Weight) -> String { "InstrumentSerif-Regular" }

    /// Fira Code (mono: code, URLs, metadata). Has a real SemiBold.
    static func mono(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: "FiraCode-Light"
        case .medium: "FiraCode-Medium"
        case .semibold: "FiraCode-SemiBold"
        case .bold, .heavy, .black: "FiraCode-Bold"
        default: "FiraCode-Regular"
        }
    }
}

extension Font {
    /// Satoshi -- the app's sans UI font. Drop-in for `.system(size:weight:)` on text.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(Typeface.sans(weight), size: size)
    }

    /// Sentient ExtraLight -- agent message reading text.
    static func serif(_ size: CGFloat) -> Font {
        .custom(Typeface.serifFamily, size: size)
    }

    /// Instrument Serif -- the display face for the app name and prominent titles.
    static func title(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(Typeface.title(weight), size: size)
    }

    /// Fira Code -- monospaced text (code, URLs, metadata).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(Typeface.mono(weight), size: size)
    }
}

/// A frosted-glass panel: translucent dark fill over a blur, with a hairline
/// border and a soft drop shadow — the HUD shell from the prototype.
private struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Palette.glassFill.opacity(0.55)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.borderStrong, lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 24)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }

    /// A 0.5pt hairline divider matching the HUD's borders.
    func hairlineDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }
}

/// Thin hairline used between HUD sections.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Palette.border).frame(height: 1)
    }
}
