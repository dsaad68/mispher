import DeepAgents
import Foundation

/// Screenshot middleware — lets a vision model look at the user's screen. It contributes a
/// `take_screenshot` tool and, once that tool captures an image, splices the image into the
/// conversation as a new human turn so the next model round can see it. (`renderMessages`
/// only attaches images to `.human` turns, and `RebuildTurnSession` rebuilds the prompt from
/// the message list each round, so editing history between rounds is honored.)
///
/// For a VLM, attach this with the default `attachToConversation: true` so the capture is
/// spliced in for the model to look at. A blind text model (e.g. the deep agent's planner)
/// attaches it with `false`: it can still capture, but the image stays in `pending_screenshots`
/// for a vision subagent to consume via `task` (see `SubAgentMiddleware`).
public struct ScreenshotMiddleware: AgentMiddleware {
    /// When `true` (default), a freshly captured screenshot is spliced into the conversation as a
    /// human turn so a vision model sees it next round. When `false`, the capture is left in
    /// `pending_screenshots` instead — the deep agent's text planner uses this so it can hand the
    /// image down to its `vision` subagent rather than (uselessly) attaching it to itself.
    let attachToConversation: Bool

    /// Where the capture tools read pixels from. Defaults to the real screen
    /// (``LiveScreenCapture``); the headless scenario harness injects a fixture provider so
    /// screen-dependent runs are deterministic and need no Screen Recording permission.
    let screenCapture: any ScreenCaptureProviding

    /// Public construction (app-side agents): real-screen capture, with no capture provider in the
    /// public signature so `ScreenCaptureProviding` can stay internal.
    public init(attachToConversation: Bool = true) {
        self.attachToConversation = attachToConversation
        screenCapture = LiveScreenCapture()
    }

    /// Construction with an injected capture provider (the scenario harness passes a fixture).
    /// `screenCapture` is required so this doesn't overlap the no-provider init above.
    public init(attachToConversation: Bool = true, screenCapture: any ScreenCaptureProviding) {
        self.attachToConversation = attachToConversation
        self.screenCapture = screenCapture
    }

    public var name: String { "screenshot" }
    public var tools: [any AgentTool] {
        [
            TakeScreenshotTool(screenCapture: screenCapture),
            ListWindowScreenshotsTool(screenCapture: screenCapture)
        ]
    }

    /// Drain any screenshots captured last round into a real human turn so the next model
    /// call renders them as image input, then clear the marker so they aren't re-attached.
    /// Skipped entirely when not attaching, so the capture survives for a subagent to forward.
    public func beforeModel(_ state: inout AgentState) async {
        guard attachToConversation else { return }
        guard let urls = state.values[ScreenshotState.pendingKey] as? [URL], !urls.isEmpty else { return }
        state.messages.append(.human("Here is the screenshot you captured.", imageURLs: urls))
        state.values[ScreenshotState.pendingKey] = nil
    }

    /// Append usage guidance to the system prompt for every model call (like
    /// `TodoListMiddleware`), so the model knows it can look at the screen — or, when it can't
    /// see images itself, that it must capture and delegate.
    public func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        let guidance = attachToConversation ? Self.systemPrompt : Self.delegatedSystemPrompt
        let composed = [request.systemPrompt, guidance]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return try await handler(request.override(systemPrompt: composed))
    }

    public static let systemPrompt = """
    ## Looking at the screen with `take_screenshot`
    You can see the user's screen. When they ask what is on their screen, in a window, or \
    what you can see — or their request only makes sense if you look — call \
    `take_screenshot`. Pass `target: "window"` for the frontmost app window (the default), \
    or `target: "screen"` for the whole display. The captured image is added to the \
    conversation automatically; once it appears, answer about what you actually see. Never \
    claim you cannot see the screen — use the tool.

    ## Listing open windows with `take_window_screenshots`
    When the user asks which windows are open, or wants every window captured separately, \
    call `take_window_screenshots`. It captures one image per open app window and returns a \
    numbered JSON list of each window's name. (It does not attach the images for you to view — \
    use `take_screenshot` when you need to look at a window yourself.)
    """

    /// Guidance for a model that captures but cannot view the image itself: capture, then hand
    /// it to the `vision` subagent. Used when `attachToConversation` is false (the deep agent).
    /// Stays tool-agnostic about *which* capture to use — the deep agent's own prompt
    /// (`DeepScreenPrompt`) routes whole-screen vs per-window captures.
    static let delegatedSystemPrompt = """
    ## Looking at the screen
    You cannot see images yourself. To answer anything visual about the user's screen, capture it \
    with the screenshot tools, then delegate the actual looking to the `vision` subagent with a \
    precise question and use its answer. Never describe the screen from memory and never claim you \
    cannot see it: capture, then delegate.
    """
}

/// The `take_screenshot` tool: capture the screen or the frontmost window for the model to
/// view. The captured file travels via a state update (not the visible result text), so the
/// model never echoes a file path into its answer.
public struct TakeScreenshotTool: AgentTool {
    /// Capture source — the real screen in the app, a fixture in the scenario harness.
    var screenCapture: any ScreenCaptureProviding = LiveScreenCapture()

    public var name: String { "take_screenshot" }
    public var description: String {
        "Capture a screenshot of the user's screen or the frontmost window so you can see "
            + "what they are looking at. The image is attached to the conversation automatically."
    }

    public var parameters: [ToolParameter] {
        [
            .optional(
                "target", type: .string,
                description: "What to capture: \"window\" for the frontmost app window "
                    + "(default), or \"screen\" for the whole display.",
                extraProperties: ["enum": ["window", "screen"]]
            )
        ]
    }

    public func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        let wantsScreen: Bool
        if case .string(let target)? = arguments["target"] {
            wantsScreen = target.lowercased() == "screen"
        } else {
            wantsScreen = false
        }

        do {
            let (url, size) = try await screenCapture.capture(fullScreen: wantsScreen)
            let what = wantsScreen ? "the screen" : "the frontmost window"
            return ToolOutput(
                "Captured \(what) (\(Int(size.width))×\(Int(size.height))). "
                    + "The image is now attached for you to look at.",
                stateUpdate: .set(ScreenshotState.pendingKey, [url])
            )
        } catch let error as ScreenshotCapture.CaptureError {
            // Surface the reason as the tool result so the agent can relay it to the user.
            return ToolOutput(error.message)
        }
    }
}

/// The `take_window_screenshots` tool: capture every open app window separately and return a
/// numbered JSON manifest of each window's name. The numbers are the visible result — the model
/// reasons about the window list and can hand a single window (by its number) to the `vision`
/// subagent via the `task` tool. The captures themselves travel via a state update
/// (`pendingWindowsKey`), never as visible text, so the model never echoes a temp path.
public struct ListWindowScreenshotsTool: AgentTool {
    /// Capture source — the real screen in the app, a fixture in the scenario harness.
    var screenCapture: any ScreenCaptureProviding = LiveScreenCapture()

    public var name: String { "take_window_screenshots" }
    public var description: String {
        "Capture every open application window separately, each at its own full resolution, and "
            + "return a numbered JSON list of the open windows (their number and name). Use it to "
            + "see what is open across apps and to capture each window for closer analysis."
    }

    public var parameters: [ToolParameter] { [] }

    /// One window's entry in the returned JSON manifest. `number` is the 1-based handle the agent
    /// passes back as the `task` tool's `window` argument to analyze that specific window.
    private struct WindowShot: Encodable {
        let number: Int
        let window: String
    }

    public func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        do {
            let captures = try await screenCapture.captureWindows()
            let manifest = captures.enumerated().map { index, capture in
                WindowShot(number: index + 1, window: capture.window)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys] // compact — fewer tokens; sorted stays deterministic
            let data = try encoder.encode(manifest)
            let json = String(bytes: data, encoding: .utf8) ?? "[]"
            // Stash the captures (in manifest order) so the `task` tool can forward one window at a
            // time to the vision subagent, addressed by the `number` shown in this list.
            return ToolOutput(
                json,
                stateUpdate: .set(ScreenshotState.pendingWindowsKey, captures.map(\.url))
            )
        } catch let error as ScreenshotCapture.CaptureError {
            // Surface the reason as the tool result so the agent can relay it to the user.
            return ToolOutput(error.message)
        }
    }
}
