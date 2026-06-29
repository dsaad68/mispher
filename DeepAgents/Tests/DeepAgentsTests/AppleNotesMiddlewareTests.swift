@testable import DeepAgents
@testable import DeepAgentsMacTools
@testable import DeepAgentsMLX
import Foundation
import MLXLMCommon
import Testing

/// The Apple Notes tools. These cover the parts that need no real Notes access: HTML body
/// construction and escaping, argument validation, result parsing, error mapping, and the
/// AppleScript being well-formed. A live create -> read -> update round-trip needs a real
/// machine with Notes Automation granted (and would trigger a TCC prompt), so it is verified
/// by hand rather than here.
struct AppleNotesMiddlewareTests {
    // MARK: - HTML body construction (the title/body quirk + escaping)

    @Test func bodyPutsTitleFirstSoNotesUsesItAsTheName() {
        let html = NotesHTML.body(title: "Groceries", text: "milk\neggs")
        #expect(html.hasPrefix("<div><b>Groceries</b></div>")) // first line becomes the title
        #expect(html.contains("milk<br>eggs")) // newlines become <br>, not literal newlines
    }

    @Test func escapeNeutralizesHTMLSignificantCharacters() {
        #expect(NotesHTML.escape("a & b") == "a &amp; b")
        #expect(NotesHTML.escape("<x>") == "&lt;x&gt;")
    }

    @Test func escapeHandlesAmpersandFirstToAvoidDoubleEscaping() {
        // The ampersand pass must run before "<"/">", or the "&" it introduces gets re-escaped.
        #expect(NotesHTML.escape("<") == "&lt;")
        #expect(NotesHTML.escape("&") == "&amp;")
    }

    @Test func contentDivHasNoTitleLine() {
        #expect(NotesHTML.contentDiv("more") == "<div>more</div>") // append/replace content only
    }

    // MARK: - Result parsing helpers

    @Test func splitSeparatesStatusFromPayload() {
        #expect(NotesScript.split("OK\nbody text").status == "OK")
        #expect(NotesScript.split("OK\nbody text").payload == "body text")
        #expect(NotesScript.split("NONE").status == "NONE")
        #expect(NotesScript.split("NONE").payload.isEmpty)
    }

    @Test func intArgumentReadsIntDoubleAndString() {
        #expect(NotesScript.intArgument(.int(3)) == 3)
        #expect(NotesScript.intArgument(.double(2.0)) == 2)
        #expect(NotesScript.intArgument(.string("5")) == 5)
        #expect(NotesScript.intArgument(nil) == 0)
        #expect(NotesScript.intArgument(.string("nope")) == 0)
    }

    @Test func disambiguationNumbersTheMatches() {
        let text = NotesScript.disambiguation("Alpha\nBeta", query: "A")
        #expect(text.contains("1. Alpha"))
        #expect(text.contains("2. Beta"))
        #expect(text.contains("index"))
    }

    @Test func disambiguationSurfacesEachMatchsIdForExactReSelection() {
        // The script emits `id<tab>name` per match; the list shows the name and its id so the
        // model can re-call with `id` when an `index` would be racy.
        let text = NotesScript.disambiguation("x-coredata://A/p1\tAlpha\nx-coredata://B/p2\tBeta", query: "A")
        #expect(text.contains("1. Alpha (id: x-coredata://A/p1)"))
        #expect(text.contains("2. Beta (id: x-coredata://B/p2)"))
        #expect(text.contains("id"))
    }

    // MARK: - Argument validation (returns before any Notes access)

    @Test func readNoteRequiresTitle() async throws {
        let out = try await ReadNoteTool().execute([:], ToolContext())
        #expect(out.content.contains("Error"))
        #expect(out.content.contains("title"))
    }

    @Test func createNoteRequiresTitle() async throws {
        let out = try await CreateNoteTool().execute(["body": .string("x")], ToolContext())
        #expect(out.content.contains("Error"))
    }

    @Test func updateNoteRequiresTitle() async throws {
        let out = try await UpdateNoteTool()
            .execute(["body": .string("x"), "mode": .string("replace")], ToolContext())
        #expect(out.content.contains("Error"))
        #expect(out.content.contains("title"))
    }

    @Test func updateNoteRequiresAValidMode() async throws {
        // Title present, mode missing -> errors before touching Notes.
        let missing = try await UpdateNoteTool()
            .execute(["title": .string("T"), "body": .string("x")], ToolContext())
        #expect(missing.content.contains("Error"))
        #expect(missing.content.contains("mode"))

        let bogus = try await UpdateNoteTool()
            .execute(["title": .string("T"), "body": .string("x"), "mode": .string("merge")], ToolContext())
        #expect(bogus.content.contains("Error"))
    }

    // MARK: - Tool surface / schema

    @Test func middlewareExposesTheFourNotesTools() {
        let names = Set(AppleNotesMiddleware().tools.map(\.name))
        #expect(names == ["list_notes", "read_note", "create_note", "update_note"])
    }

    @Test func mutatingToolsRequireTitle() {
        for tool in [ReadNoteTool(), CreateNoteTool(), UpdateNoteTool()] as [any AgentTool] {
            #expect(tool.parameters.contains { $0.name == "title" && $0.isRequired })
        }
    }

    @Test func updateModeIsRequiredAndAdvertisesReplaceAndAppend() {
        let mode = UpdateNoteTool().parameters.first { $0.name == "mode" }
        #expect(mode?.isRequired == true)
        #expect(mode?.extraProperties["enum"] as? [String] == ["replace", "append"])
    }

    @Test func readAndUpdateAdvertiseAnOptionalIdParameter() {
        // The id path lets the model re-select a note exactly after a MULTIPLE result, without
        // relying on the racy 1-based index.
        for tool in [ReadNoteTool(), UpdateNoteTool()] as [any AgentTool] {
            let id = tool.parameters.first { $0.name == "id" }
            #expect(id != nil)
            #expect(id?.isRequired == false)
        }
    }

    // MARK: - AppleScript source sanity (cheap guard against typos)

    @Test func scriptDefinesEveryHandler() {
        for handler in ["listnotes", "readnote", "createnote", "updatenote"] {
            #expect(NotesScript.source.contains("on \(handler)("))
            #expect(NotesScript.source.contains("end \(handler)"))
        }
        #expect(NotesScript.source.contains("tell application \"Notes\""))
    }

    @Test func scriptHasAnArgvEntryPointThatRoutesEachHandler() {
        // The middleware runs the script via `osascript`, which enters at `on run argv`; that
        // dispatcher must route to every handler so the Swift `call(handler:...)` names resolve.
        #expect(NotesScript.source.contains("on run argv"))
        for handler in ["listnotes", "readnote", "createnote", "updatenote"] {
            #expect(NotesScript.source.contains("my \(handler)("))
        }
    }

    @Test func argumentValueRendersStringsAndIntsForArgv() {
        #expect(NotesArg.string("hi").argumentValue == "hi")
        #expect(NotesArg.int(3).argumentValue == "3")
    }

    @Test func listingBulkFetchesNamesInsteadOfRoundTrippingEachNote() {
        // Regression guard: an earlier version filtered with `whose name contains` and pulled
        // `contents of` every match, one Apple-event round-trip per note - listing a few dozen
        // notes took ~14s and read as a freeze. The fix bulk-fetches `name`/`id of every note`
        // once and filters in memory. Keep it that way.
        #expect(NotesScript.source.contains("name of every note"))
        #expect(NotesScript.source.contains("id of every note"))
        #expect(!NotesScript.source.contains("whose name contains")) // the slow predicate
        #expect(!NotesScript.source.contains("contents of aNote")) // the per-note content load
    }

    // MARK: - Error mapping (no Notes access required)

    @Test func automationDenialMapsToGuidance() {
        let byNumber = AppleScriptError.executionFailed(number: -1743, message: "denied")
        #expect(byNumber.isAutomationDenied)
        #expect(byNumber.errorDescription?.contains("Privacy & Security > Automation") == true)

        let byMessage = AppleScriptError.executionFailed(
            number: 1, message: "Not authorized to send Apple events to Notes."
        )
        #expect(byMessage.isAutomationDenied)
    }

    @Test func nonDenialErrorPassesItsMessageThrough() {
        let other = AppleScriptError.executionFailed(number: 1, message: "some other failure")
        #expect(other.isAutomationDenied == false)
        #expect(other.errorDescription == "some other failure")
    }

    // MARK: - Live subprocess path (opt-in: needs a real machine with Notes Automation granted)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MISPHER_NOTES_LIVE"] == "1"))
    func liveListRunsThroughOsascriptAndReturnsPromptly() async throws {
        // Exercises the real `NotesScript.call` -> osascript subprocess path. Proves the call
        // returns (rather than hanging the way the in-process Apple-event send did in the TUI).
        // Run with: MISPHER_NOTES_LIVE=1 swift test --filter liveListRunsThroughOsascript
        let raw = try await NotesScript.call("listnotes", [.string(""), .string("")])
        let status = NotesScript.split(raw).status
        #expect(status == "OK" || status == "NONE")
    }

    @Test func osascriptStderrIsParsedIntoCodeAndCleanMessage() {
        // osascript writes denials like this; the trailing "(-1743)" must be recovered so the
        // mapping recognises the Automation denial, and the "execution error:"/code chrome dropped.
        let denied = AppleScriptError.from(
            osascriptError: "94:120: execution error: Not authorized to send Apple events to Notes. (-1743)",
            status: 1
        )
        #expect(denied.isAutomationDenied)
        #expect(denied.errorDescription?.contains("Privacy & Security > Automation") == true)

        let other = AppleScriptError.from(
            osascriptError: "0:10: execution error: Some Notes failure. (-2700)", status: 1
        )
        #expect(other.isAutomationDenied == false)
        #expect(other.errorDescription == "Some Notes failure.")
    }
}
