import DeepAgents
import Foundation

/// Apple Notes middleware - gives the agent tools to list, read, create, and update the user's
/// Apple Notes by driving Notes.app through AppleScript, plus the guidance for using them. Each
/// tool runs one handler of a fixed script via ``NotesScript``, which spawns `/usr/bin/osascript`
/// and passes all user-supplied data (title, body, folder, query, index, id) as `osascript`
/// arguments (the script's `on run argv`), never interpolated into the source - so there is no
/// AppleScript injection.
///
/// The script runs in a subprocess on purpose. An in-process `NSAppleScript` send waits for the
/// cross-process Apple-event reply on the host's run loop, and `ripple`'s full-screen TUI doesn't
/// pump one in a way that dispatches it - so the event reaches Notes (the note is even created)
/// but the reply never arrives and the agent hangs. osascript runs the script in its own process
/// with its own run loop; we only wait for the process to exit and read its stdout, off the main
/// thread, so a slow Notes call never freezes the caller.
///
/// Notes derives a note's title from the first line of its HTML `body`, so the create/update
/// tools build the body HTML here (escaped, newlines as `<br>`) and the script only assigns
/// `body`.
///
/// Writes (`create_note` / `update_note`) are meant to be gated behind the human-in-the-loop
/// approval card (see ``MispherDeepAgent``): the card shows the exact title/body/mode, so the
/// user catches a wrong-note overwrite before it happens. Reads stay ungated.
public struct AppleNotesMiddleware: AgentMiddleware {
    public init() {}
    public var name: String { "apple_notes" }
    public var tools: [any AgentTool] {
        [ListNotesTool(), ReadNoteTool(), CreateNoteTool(), UpdateNoteTool()]
    }

    /// Append the Notes guidance so the tool names and usage rules travel with the tools
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
    ## Apple Notes with `list_notes` / `read_note` / `create_note` / `update_note`
    You can read and write the user's Apple Notes - never claim you can't, and never guess a \
    note's contents: call `read_note`. Use `list_notes` to find notes by title (pass `query` to \
    filter), `read_note` to read one, `create_note` to make a new one, and `update_note` to \
    change one. Notes are matched by title; if several match you'll get a numbered list - read \
    or update the one you want by re-calling with `index` set to its number (or `id` set to the \
    exact note id shown). For `update_note` you must set `mode`: "append" adds to the end and is \
    safe; "replace" overwrites the whole body (formatting, checklists, and attachments included), \
    keeping only the title, so prefer "append" unless the user clearly wants a rewrite. Telling \
    the user some text is not the same as saving it - to save a note you must call `create_note` \
    or `update_note`.
    """
}

// MARK: - AppleScript runner

/// A small, Sendable argument for a Notes script handler. The tools build these off the main
/// actor (only `String`/`Int`); ``NotesScript/call(_:_:)`` passes them to `osascript` as `argv`
/// strings, so an `Int` index is just rendered as its decimal text.
enum NotesArg: Sendable {
    case string(String)
    case int(Int)

    /// The value as the plain string handed to `osascript` as an `on run argv` element.
    var argumentValue: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        }
    }
}

/// Runs the bundled Notes AppleScript via `osascript`, invoking one of its handlers and passing
/// arguments safely as `argv` (never interpolated into the source). Returns the handler's string
/// result. Each handler returns a status token on its first line (`OK` / `NONE` / `MULTIPLE` /
/// `OOR` / `NOFOLDER`) followed by a payload, which the tools parse with ``split(_:)``.
enum NotesScript {
    /// The full script: helpers plus one handler per tool. Handler names are lowercase because
    /// AppleScript stores and matches subroutine names lowercased. `matchnotes` bulk-fetches every
    /// note's id and name in one pass each (folder-scoped when a folder is given) and filters by
    /// title in memory, returning `missing value` for an unknown folder (mapped to `NOFOLDER`).
    /// This is deliberate: pulling a note's `contents` per match, or using a `whose name contains`
    /// query, makes Notes round-trip per note and turns listing or disambiguating a few dozen notes
    /// into a multi-second hang - bulk `name of every note` / `id of every note` plus an in-memory
    /// filter keeps it well under a second. `read`/`update` resolve a note directly by `id` when one
    /// is given, else pick by `index` (1-based) or report `MULTIPLE` with each match's id and name;
    /// `update`'s `replace` rebuilds the title `<div>` from the note's current name so the title is
    /// preserved. `plaintext` is read with a `body` fallback.
    static let source = #"""
    on replacetext(theText, searchString, replacementString)
        set savedDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to searchString
        set theItems to text items of theText
        set AppleScript's text item delimiters to replacementString
        set theText to theItems as text
        set AppleScript's text item delimiters to savedDelimiters
        return theText
    end replacetext

    on escapehtml(theText)
        set theText to my replacetext(theText, "&", "&amp;")
        set theText to my replacetext(theText, "<", "&lt;")
        set theText to my replacetext(theText, ">", "&gt;")
        return theText
    end escapehtml

    on matchnotes(theQuery, theFolderName)
        tell application "Notes"
            if theFolderName is not "" then
                try
                    set theNames to name of every note of folder theFolderName
                    set theIDs to id of every note of folder theFolderName
                on error
                    return missing value
                end try
            else
                set theNames to name of every note
                set theIDs to id of every note
            end if
        end tell
        if theQuery is "" then return {theIDs, theNames}
        set keptIDs to {}
        set keptNames to {}
        repeat with i from 1 to count of theNames
            set aName to item i of theNames
            if aName contains theQuery then
                set end of keptIDs to item i of theIDs
                set end of keptNames to aName
            end if
        end repeat
        return {keptIDs, keptNames}
    end matchnotes

    on notebyid(theID)
        tell application "Notes"
            try
                return note id theID
            on error
                return missing value
            end try
        end tell
    end notebyid

    on notepayload(theNote)
        tell application "Notes"
            set noteName to name of theNote
            try
                set bodyText to plaintext of theNote
            on error
                set bodyText to body of theNote
            end try
            return "OK" & linefeed & noteName & linefeed & linefeed & bodyText
        end tell
    end notepayload

    on multiplelist(theIDs, theNames)
        set out to "MULTIPLE"
        repeat with i from 1 to count of theIDs
            set out to out & linefeed & (item i of theIDs) & tab & (item i of theNames)
        end repeat
        return out
    end multiplelist

    on applyupdate(theNote, theContentHTML, theMode)
        tell application "Notes"
            if theMode is "append" then
                set body of theNote to (body of theNote) & theContentHTML
            else
                set body of theNote to ("<div><b>" & my escapehtml(name of theNote) & "</b></div>") & theContentHTML
            end if
            return "OK" & linefeed & (name of theNote)
        end tell
    end applyupdate

    on listnotes(theQuery, theFolderName)
        set theMatches to my matchnotes(theQuery, theFolderName)
        if theMatches is missing value then return "NOFOLDER"
        set theNames to item 2 of theMatches
        if (count of theNames) is 0 then return "NONE"
        set out to "OK"
        repeat with aName in theNames
            set out to out & linefeed & aName
        end repeat
        return out
    end listnotes

    on readnote(theQuery, theFolderName, theIndex, theID)
        if theID is not "" then
            set theNote to my notebyid(theID)
            if theNote is missing value then return "NONE"
            return my notepayload(theNote)
        end if
        set theMatches to my matchnotes(theQuery, theFolderName)
        if theMatches is missing value then return "NOFOLDER"
        set theIDs to item 1 of theMatches
        set theNames to item 2 of theMatches
        set matchCount to count of theIDs
        if matchCount is 0 then return "NONE"
        if theIndex > 0 then
            if theIndex > matchCount then return "OOR" & linefeed & matchCount
            set chosenID to item theIndex of theIDs
        else if matchCount is 1 then
            set chosenID to item 1 of theIDs
        else
            return my multiplelist(theIDs, theNames)
        end if
        set theNote to my notebyid(chosenID)
        if theNote is missing value then return "NONE"
        return my notepayload(theNote)
    end readnote

    on createnote(theBodyHTML, theFolderName)
        tell application "Notes"
            if theFolderName is not "" then
                try
                    set newNote to make new note at folder theFolderName with properties {body:theBodyHTML}
                on error
                    return "NOFOLDER"
                end try
            else
                set newNote to make new note with properties {body:theBodyHTML}
            end if
            return "OK" & linefeed & (name of newNote)
        end tell
    end createnote

    on updatenote(theQuery, theContentHTML, theMode, theFolderName, theIndex, theID)
        if theID is not "" then
            set theNote to my notebyid(theID)
            if theNote is missing value then return "NONE"
            return my applyupdate(theNote, theContentHTML, theMode)
        end if
        set theMatches to my matchnotes(theQuery, theFolderName)
        if theMatches is missing value then return "NOFOLDER"
        set theIDs to item 1 of theMatches
        set theNames to item 2 of theMatches
        set matchCount to count of theIDs
        if matchCount is 0 then return "NONE"
        if theIndex > 0 then
            if theIndex > matchCount then return "OOR" & linefeed & matchCount
            set chosenID to item theIndex of theIDs
        else if matchCount is 1 then
            set chosenID to item 1 of theIDs
        else
            return my multiplelist(theIDs, theNames)
        end if
        set theNote to my notebyid(chosenID)
        if theNote is missing value then return "NONE"
        return my applyupdate(theNote, theContentHTML, theMode)
    end updatenote

    on run argv
        set theHandler to item 1 of argv
        if theHandler is "listnotes" then
            return my listnotes(item 2 of argv, item 3 of argv)
        else if theHandler is "readnote" then
            return my readnote(item 2 of argv, item 3 of argv, (item 4 of argv) as integer, item 5 of argv)
        else if theHandler is "createnote" then
            return my createnote(item 2 of argv, item 3 of argv)
        else if theHandler is "updatenote" then
            set theIndex to (item 6 of argv) as integer
            return my updatenote(item 2 of argv, item 3 of argv, item 4 of argv, item 5 of argv, theIndex, item 7 of argv)
        end if
        error "unknown Notes handler: " & theHandler
    end run
    """#

    /// Runs the blocking `osascript` work off the main thread so waiting on the subprocess never
    /// stalls the agent loop / TUI. Each call is an independent process, so this need not be serial.
    private static let queue = DispatchQueue(label: "com.mispher.notes.osascript", attributes: .concurrent)

    /// Invoke one script handler by spawning `osascript`, passing the handler name and `args` as
    /// `on run argv` elements, and return its string result. Suspends the calling task (never the
    /// UI) until the process exits. Throws ``AppleScriptError`` when osascript fails - including the
    /// Notes Automation-permission denial (AE error -1743).
    static func call(_ handler: String, _ args: [NotesArg]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try continuation.resume(returning: run(handler, args))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Spawn `/usr/bin/osascript`, feed it the script on stdin, and pass `handler` + `args` as the
    /// process arguments (which become `argv` in `on run argv`). Always called on ``queue``, off the
    /// main thread, because it blocks on the subprocess.
    private static func run(_ handler: String, _ args: [NotesArg]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // "-" reads the script from stdin; the trailing arguments become `argv` in `on run argv` -
        // user data travels as arguments, never as source, so there is no AppleScript injection.
        process.arguments = ["-", handler] + args.map(\.argumentValue)

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw AppleScriptError.compileFailed("couldn't launch osascript (\(error.localizedDescription)).")
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        // Read stdout first, then stderr. On success stderr is empty; on failure stdout is empty -
        // so neither pipe can fill while we drain the other, and this can't deadlock.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AppleScriptError.from(
                osascriptError: String(bytes: errorData, encoding: .utf8) ?? "",
                status: process.terminationStatus
            )
        }
        var result = String(bytes: outputData, encoding: .utf8) ?? ""
        if result.hasSuffix("\n") { result.removeLast() } // osascript appends a trailing newline
        return result
    }

    /// Split a handler result into its first-line status token and the remaining payload.
    static func split(_ raw: String) -> (status: String, payload: String) {
        guard let newline = raw.firstIndex(of: "\n") else { return (raw, "") }
        return (String(raw[..<newline]), String(raw[raw.index(after: newline)...]))
    }

    /// Read an optional integer tool argument a model may emit as an int, a double, or a string.
    static func intArgument(_ value: AgentJSON?) -> Int {
        switch value {
        case .int(let number): return number
        case .double(let number): return Int(number)
        case .string(let text): return Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
        default: return 0
        }
    }

    /// Render a `MULTIPLE` payload (one `id<tab>title` per line) as a numbered list the model
    /// picks from by re-calling with `index` (simple) or `id` (exact). The id is shown so the
    /// model can disambiguate unambiguously when an `index` would be racy.
    static func disambiguation(_ payload: String, query: String) -> String {
        let numbered = payload
            .split(separator: "\n", omittingEmptySubsequences: true)
            .enumerated()
            .map { offset, line -> String in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return "\(offset + 1). \(line)" }
                return "\(offset + 1). \(parts[1]) (id: \(parts[0]))"
            }
            .joined(separator: "\n")
        return "Multiple notes match \"\(query)\":\n\(numbered)\n"
            + "Re-call with `index` set to the number you want, or `id` set to the exact note id."
    }
}

/// Why a Notes script failed, mapped to a model- and user-readable message.
enum AppleScriptError: LocalizedError {
    case compileFailed(String)
    case executionFailed(number: Int, message: String)

    /// Map `osascript`'s stderr (e.g. `"execution error: Not authorized to send Apple events to
    /// Notes. (-1743)"`) to an `executionFailed`, recovering the AE error number from the trailing
    /// `(-NNNN)` so ``isAutomationDenied`` can spot the -1743 denial.
    static func from(osascriptError raw: String, status: Int32) -> AppleScriptError {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = trailingErrorCode(in: trimmed) ?? Int(status)
        var message = trimmed
        if let range = message.range(of: "execution error: ") {
            message = String(message[range.upperBound...])
        }
        if let open = message.range(of: " (", options: .backwards), message.hasSuffix(")") {
            message = String(message[..<open.lowerBound])
        }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return .executionFailed(number: number, message: message.isEmpty ? "the Notes script failed." : message)
    }

    /// The integer inside a trailing `(...)` - osascript ends a message with the AE error code.
    private static func trailingErrorCode(in text: String) -> Int? {
        guard text.hasSuffix(")"), let open = text.range(of: "(", options: .backwards) else { return nil }
        let inside = text[text.index(after: open.lowerBound) ..< text.index(before: text.endIndex)]
        return Int(inside)
    }

    /// True for the TCC "not authorized to send Apple events" denial - osascript/AE error -1743.
    var isAutomationDenied: Bool {
        if case .executionFailed(let number, let message) = self {
            return number == -1743 || message.localizedCaseInsensitiveContains("Not authorized")
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .compileFailed(let message):
            return "couldn't compile the Notes script (\(message))."
        case .executionFailed(_, let message):
            if isAutomationDenied {
                return "Mispher isn't allowed to control Notes yet. Grant permission in "
                    + "System Settings > Privacy & Security > Automation - enable Notes for "
                    + "Mispher - then try again."
            }
            return message
        }
    }
}

// MARK: - HTML helpers (a note's body is HTML; its first line becomes the title)

/// Turns plain text into the simple HTML `body` Notes expects. Rich formatting is not
/// reconstructed - just escaped paragraphs with `<br>` line breaks.
enum NotesHTML {
    /// Escape the HTML-significant characters (ampersand first, so it doesn't double-escape).
    static func escape(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }

    /// `<div><b>title</b></div><div>body</div>` - Notes makes the first line the title.
    static func body(title: String, text: String) -> String {
        "<div><b>\(escape(title))</b></div>" + contentDiv(text)
    }

    /// A single `<div>` of body text with newlines as `<br>` and no title line.
    static func contentDiv(_ text: String) -> String {
        "<div>\(escape(text).replacingOccurrences(of: "\n", with: "<br>"))</div>"
    }
}

// MARK: - Tools

/// `list_notes`: list note titles, optionally filtered by a `query` substring and/or `folder`.
public struct ListNotesTool: AgentTool {
    public var name: String { "list_notes" }
    public var description: String {
        "List the titles of the user's Apple Notes. Pass `query` to keep only titles containing "
            + "that text, and `folder` to look in one folder. Returns one title per line."
    }

    public var parameters: [ToolParameter] {
        [
            .optional("query", type: .string, description: "Substring to filter titles by. Omit for all notes."),
            .optional("folder", type: .string, description: "Folder name to list within. Omit for all folders.")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        var query = ""
        if case .string(let value)? = arguments["query"] { query = value }
        var folder = ""
        if case .string(let value)? = arguments["folder"] { folder = value }
        do {
            let raw = try await NotesScript.call("listnotes", [.string(query), .string(folder)])
            let (status, payload) = NotesScript.split(raw)
            if status == "NOFOLDER" { return ToolOutput("Error: no folder named \"\(folder)\".") }
            guard status == "OK", !payload.isEmpty else {
                let match = query.isEmpty ? "" : " matching \"\(query)\""
                let scope = folder.isEmpty ? "" : " in folder \"\(folder)\""
                return ToolOutput("No notes\(match)\(scope).")
            }
            return ToolOutput(payload)
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// `read_note`: return the plain-text body of the note whose title contains `title` (picking by
/// `index` or `id` when several match).
public struct ReadNoteTool: AgentTool {
    public var name: String { "read_note" }
    public var description: String {
        "Read one of the user's Apple Notes by title. Returns the note's title and its plain-text "
            + "body. If several notes match, returns a numbered list instead - re-call with `index` "
            + "set to the number you want, or `id` set to the exact note id shown."
    }

    public var parameters: [ToolParameter] {
        [
            .required("title", type: .string, description: "Text to find in the note's title."),
            .optional("folder", type: .string, description: "Folder to search within. Omit for all folders."),
            .optional("index", type: .int, description: "When several notes match, the 1-based number of the one to read."),
            .optional("id", type: .string, description: "An exact note id from a previous result. When set, reads that note directly.")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard case .string(let title)? = arguments["title"], !title.isEmpty else {
            return ToolOutput("Error: `title` is required.")
        }
        var folder = ""
        if case .string(let value)? = arguments["folder"] { folder = value }
        var id = ""
        if case .string(let value)? = arguments["id"] { id = value }
        let index = NotesScript.intArgument(arguments["index"])
        do {
            let raw = try await NotesScript.call(
                "readnote", [.string(title), .string(folder), .int(index), .string(id)]
            )
            let (status, payload) = NotesScript.split(raw)
            switch status {
            case "OK": return ToolOutput(payload)
            case "MULTIPLE": return ToolOutput(NotesScript.disambiguation(payload, query: title))
            case "OOR":
                return ToolOutput("Error: index \(index) is out of range; \(payload) notes match \"\(title)\".")
            case "NOFOLDER": return ToolOutput("Error: no folder named \"\(folder)\".")
            default:
                return ToolOutput("Error: no note found with a title containing \"\(title)\".")
            }
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// `create_note`: make a new Apple Note with the given title and body.
public struct CreateNoteTool: AgentTool {
    public var name: String { "create_note" }
    public var description: String {
        "Create a new Apple Note with the given `title` and `body`. Optionally place it in `folder`."
    }

    public var parameters: [ToolParameter] {
        [
            .required("title", type: .string, description: "The new note's title."),
            .required("body", type: .string, description: "The note's body text. Use \\n for line breaks."),
            .optional("folder", type: .string, description: "Folder to create the note in. Omit for the default.")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard case .string(let title)? = arguments["title"], !title.isEmpty else {
            return ToolOutput("Error: `title` is required.")
        }
        var body = ""
        if case .string(let value)? = arguments["body"] { body = value }
        var folder = ""
        if case .string(let value)? = arguments["folder"] { folder = value }
        let html = NotesHTML.body(title: title, text: body)
        do {
            let raw = try await NotesScript.call("createnote", [.string(html), .string(folder)])
            let (status, payload) = NotesScript.split(raw)
            if status == "NOFOLDER" { return ToolOutput("Error: no folder named \"\(folder)\".") }
            guard status == "OK" else { return ToolOutput("Error: couldn't create the note.") }
            return ToolOutput("Created the note \"\(payload)\".")
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}

/// `update_note`: replace or append the body of the note whose title contains `title` (picking by
/// `index` or `id` when several match). `mode` is required.
public struct UpdateNoteTool: AgentTool {
    public var name: String { "update_note" }
    public var description: String {
        "Update an existing Apple Note found by `title`. `mode` is required: \"replace\" rewrites "
            + "the body (the note keeps its title) or \"append\" adds to the end. If several notes "
            + "match, returns a numbered list - re-call with `index` set to the number you want, or "
            + "`id` set to the exact note id shown."
    }

    public var parameters: [ToolParameter] {
        [
            .required("title", type: .string, description: "Text to find in the note's title."),
            .required("body", type: .string, description: "The new or additional body text. Use \\n for line breaks."),
            .required(
                "mode", type: .string,
                description: "\"replace\" overwrites the body; \"append\" adds to the end.",
                extraProperties: ["enum": ["replace", "append"]]
            ),
            .optional("folder", type: .string, description: "Folder to search within. Omit for all folders."),
            .optional("index", type: .int, description: "When several notes match, the 1-based number of the one to update."),
            .optional("id", type: .string, description: "An exact note id from a previous result. When set, updates that note directly.")
        ]
    }

    public func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        guard case .string(let title)? = arguments["title"], !title.isEmpty else {
            return ToolOutput("Error: `title` is required.")
        }
        guard case .string(let mode)? = arguments["mode"], mode == "replace" || mode == "append" else {
            return ToolOutput("Error: `mode` is required; use \"replace\" or \"append\".")
        }
        var body = ""
        if case .string(let value)? = arguments["body"] { body = value }
        var folder = ""
        if case .string(let value)? = arguments["folder"] { folder = value }
        var id = ""
        if case .string(let value)? = arguments["id"] { id = value }
        let index = NotesScript.intArgument(arguments["index"])
        let html = NotesHTML.contentDiv(body)
        do {
            let raw = try await NotesScript.call(
                "updatenote", [.string(title), .string(html), .string(mode), .string(folder), .int(index), .string(id)]
            )
            let (status, payload) = NotesScript.split(raw)
            switch status {
            case "OK":
                return ToolOutput("\(mode == "append" ? "Appended to" : "Updated") the note \"\(payload)\".")
            case "MULTIPLE": return ToolOutput(NotesScript.disambiguation(payload, query: title))
            case "OOR":
                return ToolOutput("Error: index \(index) is out of range; \(payload) notes match \"\(title)\".")
            case "NOFOLDER": return ToolOutput("Error: no folder named \"\(folder)\".")
            default:
                return ToolOutput("Error: no note found with a title containing \"\(title)\".")
            }
        } catch {
            return ToolOutput("Error: \(error.localizedDescription)")
        }
    }
}
