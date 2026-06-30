@testable import Mispher
import Testing

/// The view-model glue around the agent: friendly tool-name labels shown in the UI.
@MainActor
struct ViewModelTests {
    @Test func friendlyToolNamesMapKnownTools() {
        #expect(TranscriptionViewModel.friendlyToolName("read_clipboard") == "clipboard read")
        #expect(TranscriptionViewModel.friendlyToolName("write_clipboard") == "clipboard write")
        #expect(TranscriptionViewModel.friendlyToolName("write_todos") == "to-do list")
        #expect(TranscriptionViewModel.friendlyToolName("current_datetime") == "date & time")
        #expect(TranscriptionViewModel.friendlyToolName("calculator") == "calculator")
    }

    @Test func friendlyToolNameFallsBackToRawName() {
        #expect(TranscriptionViewModel.friendlyToolName("mystery_tool") == "mystery_tool")
    }
}
