/// The agent-state convention for screenshots in flight, owned by the framework so the
/// subagent/ReAct machinery can forward captured images to a vision subagent without
/// depending on the concrete (platform-specific) screenshot tool. A capture tool — e.g.
/// `DeepAgentsMacTools`' `ScreenshotMiddleware` — stashes image URLs under these keys, and
/// `SubAgentMiddleware` / `ReactAgent` read them back.
public enum ScreenshotState {
    /// State key under which a capture tool stashes freshly captured image URLs, for the
    /// screenshot middleware's `beforeModel` to drain into the conversation (and for
    /// `ReactAgent` to read so a thumbnail can be surfaced on the tool step).
    public static let pendingKey = "pending_screenshots"

    /// State key under which a per-window capture tool stashes the ordered captures
    /// (front-to-back, matching the numbered manifest it returns). The deep agent's `task`
    /// tool reads one entry by its window number to forward just that window's image to the
    /// `vision` subagent; unlike `pendingKey`, this is pull-based and survives across
    /// delegations.
    public static let pendingWindowsKey = "pending_window_screenshots"
}
