import MarkdownUI
import SwiftUI

/// The body typeface for rendered markdown: agent **messages** read in the serif (Sentient
/// ExtraLight); agent **thinking** reads in italic sans (Satoshi).
enum MarkdownBodyFont { case serif, sans, sansItalic }

/// Renders chat markdown with MarkdownUI — full GitHub-flavored markdown (tables,
/// task lists, blockquotes, fenced code, lists, thematic breaks, …) — themed to
/// the app's dark glass palette.
struct MarkdownText: View {
    let text: String
    var color: Color
    var fontSize: CGFloat
    var bodyFont: MarkdownBodyFont

    init(_ text: String, color: Color = Palette.fg, fontSize: CGFloat = 12, bodyFont: MarkdownBodyFont = .serif) {
        self.text = text
        self.color = color
        self.fontSize = fontSize
        self.bodyFont = bodyFont
    }

    /// The MarkdownUI family name for the body prose (emphasis/strong resolve within the family).
    private var bodyFamily: String {
        switch bodyFont {
        case .serif: Typeface.serifFamily
        case .sans, .sansItalic: Typeface.sansFamily
        }
    }

    /// Sentient ExtraLight sets tight; a little tracking unclumps the serif glyphs. The sans body
    /// (agent thinking) reads fine at its default spacing, so it gets none.
    private var bodyTracking: CGFloat { bodyFont == .serif ? 0.5 : 0 }

    var body: some View {
        Markdown(text)
            .markdownTextStyle {
                FontFamily(.custom(bodyFamily))
                FontSize(fontSize)
                ForegroundColor(color)
                TextTracking(bodyTracking)
            }
            .markdownTextStyle(\.code) {
                FontFamily(.custom(Typeface.monoFamily))
                FontSize(fontSize - 1)
                ForegroundColor(Palette.fg1)
                BackgroundColor(.white.opacity(0.08))
            }
            .markdownTextStyle(\.link) {
                ForegroundColor(Palette.accent)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontFamily(.custom(Typeface.monoFamily))
                        FontSize(fontSize - 1)
                        ForegroundColor(Palette.fg1)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black.opacity(0.28)))
            }
            .markdownBlockStyle(\.blockquote) { configuration in
                configuration.label
                    .markdownTextStyle { ForegroundColor(Palette.fg2) }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(Palette.accentGlow).frame(width: 2)
                    }
            }
            // Thinking renders in italic sans; messages render upright.
            .italic(bodyFont == .sansItalic)
    }
}
