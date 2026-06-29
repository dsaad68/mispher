import AppKit
import DeepAgents
import Foundation

/// Clipboard middleware — gives the agent tools to read from and write to the macOS
/// pasteboard, plus the guidance for using them. `NSPasteboard` is main-thread-only, so
/// both tools hop to the main actor.
public struct ClipboardMiddleware: AgentMiddleware {
    public init() {}
    public var name: String { "clipboard" }
    public var tools: [any AgentTool] { [ReadClipboardTool(), WriteClipboardTool()] }

    /// Append the clipboard guidance so tool names and usage rules travel with the tools
    /// (an agent's own prompt never enumerates another component's tools).
    public func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        let composed = [request.systemPrompt, Self.systemPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return try await handler(request.override(systemPrompt: composed))
    }

    public static let systemPrompt = """
    ## Clipboard with `read_clipboard` / `write_clipboard`
    You can access the macOS clipboard — never claim you can't, and never guess its \
    contents: call `read_clipboard`. To work with the clipboard's text (translate, \
    summarize, answer about it), first call `read_clipboard`, then do the work yourself \
    in your reply. Telling the user a value is not saving it — to copy or save \
    something you must call `write_clipboard`.
    """
}

/// Read the current text contents of the macOS clipboard. The result is a small JSON
/// object (`{"clipboard_text": …}`) rather than the bare text: an unlabeled fragment in a
/// `tool` turn reads as noise to small models (observed on-device: the model re-called
/// the tool to "check" an answer it already had), while the docs' JSON shape is
/// self-describing.
public struct ReadClipboardTool: AgentTool {
    public var name: String { "read_clipboard" }
    public var description: String {
        "Read the current text contents of the macOS clipboard. "
            + "Returns {\"clipboard_text\": \"…\"}."
    }

    public func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        let text = await MainActor.run { NSPasteboard.general.string(forType: .string) }
        var object: [String: String] = ["clipboard_text": text ?? ""]
        if text?.isEmpty != false {
            object["note"] = "The clipboard is empty or contains no text."
        }
        // Don't escape forward slashes: a copied file path must come back verbatim
        // (`/Users/...`, not `\/Users\/...`), or small models mangle it when echoing it
        // into a `read_file` call - observed on-device: an escaped path got elided to
        // `/Users/dsaad/.../links.md` and the read failed.
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.withoutEscapingSlashes]
        ), let json = String(data: data, encoding: .utf8)
        else { return ToolOutput(text ?? "") }
        return ToolOutput(json)
    }
}

/// Replace the macOS clipboard contents with the given text.
public struct WriteClipboardTool: AgentTool {
    public var name: String { "write_clipboard" }
    public var description: String { "Replace the macOS clipboard contents with the given text." }

    public var parameters: [ToolParameter] {
        [.required("text", type: .string, description: "The text to place on the clipboard.")]
    }

    public func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        guard case .string(let text)? = arguments["text"] else {
            return ToolOutput("Error: `text` is required.")
        }
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        return ToolOutput("Copied to the clipboard: \"\(text)\"")
    }
}
