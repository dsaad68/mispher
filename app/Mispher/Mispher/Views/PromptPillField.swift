import AppKit
import SwiftUI

/// One placeholder kind an editable prompt can contain (e.g. `{{SELECTION}}` shown as "Selected
/// text"). The `token` is the literal substring stored in the saved prompt; `label` is the text
/// drawn inside its pill.
struct PromptToken: Equatable, Sendable {
    let token: String
    let label: String
}

/// A request to drop a pill at the caret. The parent bumps `counter` (and sets `token`) from an
/// "Insert" button; the field reacts to the changed counter.
struct PromptPillInsert: Equatable {
    var counter = 0
    var token = ""
}

/// A monospaced rich-text editor for an editable agent prompt where each ``PromptToken`` renders as
/// an atomic accent pill. The bound `text` stays a plain string with the literal tokens, so
/// persistence and prompt composition are untouched -- the pills are purely how placeholders are
/// shown and edited.
///
/// Backed by `NSTextView` because SwiftUI's `TextEditor` can't render inline, atomic tokens. Each
/// pill behaves as a single character: the caret can't enter it and one Delete removes it.
struct PromptPillField: NSViewRepresentable {
    @Binding var text: String
    /// The placeholder kinds this field renders as pills.
    var tokens: [PromptToken]
    /// Insert-a-pill request from the parent's buttons.
    var insert: PromptPillInsert

    /// Marks an attachment run with the literal token it stands for, so the plain string round-trips.
    private static let tokenKey = NSAttributedString.Key("mispher.promptToken")
    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let pillFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5 // room so the taller pills don't crowd wrapped lines
        return style
    }()

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor(Palette.fg), .paragraphStyle: paragraphStyle]
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = true // required for the pill attachment to survive editing
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor(Palette.fg)
        textView.font = Self.font
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.insertionPointColor = NSColor(Palette.fg)
        textView.textContainerInset = NSSize(width: 5, height: 7)
        textView.typingAttributes = Self.baseAttributes
        // Keep the literal tokens intact if the user types them by hand (no smart quotes/dashes).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsImageEditing = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        textView.textStorage?.setAttributedString(Self.attributed(from: text, tokens: tokens))
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        // Rebuild only on an external change (Reset, or another view edited the prompt) — never on
        // our own keystroke echo, which would stomp the caret.
        if Self.tokenString(from: textView.textStorage ?? NSAttributedString()) != text {
            coordinator.programmaticChange = true
            textView.textStorage?.setAttributedString(Self.attributed(from: text, tokens: tokens))
            coordinator.programmaticChange = false
        }

        if insert.counter != coordinator.lastInsertCounter {
            coordinator.lastInsertCounter = insert.counter
            if let match = tokens.first(where: { $0.token == insert.token }) {
                coordinator.insertPill(into: textView, token: match.token, label: match.label)
            }
        }
    }

    // MARK: - Token <-> attributed conversion

    /// Build the displayed attributed string: walk the plain string, turning every token occurrence
    /// (of any kind) into its pill and leaving the rest as monospaced text.
    private static func attributed(from string: String, tokens: [PromptToken]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let ns = string as NSString
        var location = 0
        while location < ns.length {
            var best: (range: NSRange, token: PromptToken)?
            for token in tokens {
                let range = ns.range(of: token.token, options: [], range: NSRange(location: location, length: ns.length - location))
                if range.location != NSNotFound, best == nil || range.location < best!.range.location {
                    best = (range, token)
                }
            }
            guard let best else {
                result.append(NSAttributedString(string: ns.substring(from: location), attributes: baseAttributes))
                break
            }
            if best.range.location > location {
                let pre = ns.substring(with: NSRange(location: location, length: best.range.location - location))
                result.append(NSAttributedString(string: pre, attributes: baseAttributes))
            }
            result.append(pillAttachmentString(token: best.token.token, label: best.token.label))
            location = best.range.location + best.range.length
        }
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Recover the plain token string from the editor: each pill attachment becomes the literal
    /// token it carries, every other character stays as typed.
    static func tokenString(from storage: NSAttributedString) -> String {
        let ns = storage.string as NSString
        let result = NSMutableString()
        storage.enumerateAttribute(tokenKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let token = value as? String {
                result.append(token)
            } else {
                result.append(ns.substring(with: range))
            }
        }
        return result as String
    }

    private static func pillAttachmentString(token: String, label: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let image = pillImage(label: label)
        attachment.image = image
        // Centre the pill on the line: offset from the baseline by half the gap above/below.
        let midline = (font.ascender + font.descender) / 2
        attachment.bounds = CGRect(x: 0, y: midline - image.size.height / 2, width: image.size.width, height: image.size.height)
        let result = NSMutableAttributedString(attachment: attachment)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(tokenKey, value: token, range: full)
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: full)
        return result
    }

    private static func pillImage(label: String) -> NSImage {
        let accent = NSColor(Palette.accent)
        let attrs: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: accent]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let padH: CGFloat = 8, padV: CGFloat = 3, marginH: CGFloat = 4 // marginH = breathing room from neighbouring text
        let pillW = ceil(textSize.width) + padH * 2
        let pillH = ceil(textSize.height) + padV * 2
        let size = NSSize(width: pillW + marginH * 2, height: pillH)

        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(x: marginH, y: 0, width: pillW, height: pillH).insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        accent.withAlphaComponent(0.16).setFill(); path.fill()
        accent.withAlphaComponent(0.55).setStroke(); path.lineWidth = 0.75; path.stroke()
        (label as NSString).draw(at: NSPoint(x: marginH + padH, y: padV), withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptPillField
        weak var textView: NSTextView?
        var lastInsertCounter = 0
        /// Set while we mutate the storage ourselves, so the change isn't echoed back to the binding.
        var programmaticChange = false

        init(_ parent: PromptPillField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !programmaticChange, let textView = notification.object as? NSTextView else { return }
            parent.text = PromptPillField.tokenString(from: textView.textStorage ?? NSAttributedString())
        }

        func insertPill(into textView: NSTextView, token: String, label: String) {
            // `insertText` handles undo, the delegate notification, and advancing the caret past the
            // pill; `programmaticChange` keeps that notification from echoing back to the binding.
            programmaticChange = true
            let pill = PromptPillField.pillAttachmentString(token: token, label: label)
            textView.insertText(pill, replacementRange: textView.selectedRange())
            programmaticChange = false
            // Push the new token string and refocus off the update cycle so we don't mutate SwiftUI
            // state mid-render.
            let newText = PromptPillField.tokenString(from: textView.textStorage ?? NSAttributedString())
            DispatchQueue.main.async { [weak self] in
                self?.parent.text = newText
                textView.window?.makeFirstResponder(textView)
            }
        }
    }
}
