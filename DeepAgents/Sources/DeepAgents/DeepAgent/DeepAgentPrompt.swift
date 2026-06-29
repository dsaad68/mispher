import Foundation

/// The base system prompt for a deep agent — the opinionated guidance deepagents prepends to teach
/// the model to plan, delegate, use its filesystem, and verify. `createDeepAgent` composes this
/// with the caller's own system prompt; the planning / filesystem / subagent middleware each add
/// their own tool-specific notes on top.
///
/// Deliberately short and free of caveats: the small LFM models follow a handful of unambiguous
/// rules far better than long prose, and a "skip planning for simple tasks" escape hatch here
/// would contradict agents (like the deep screen agent) that mandate planning — when/whether to
/// plan is the concrete agent's call, stated in its own prompt.
public enum DeepAgentPrompt {
    /// The base prompt, naming only the pillars actually registered: the planning and
    /// subagent pillars are always in the deep-agent stack, but the filesystem one is
    /// optional (`includeFilesystem`) — mentioning `write_file` without the tool would
    /// have the model calling a tool that doesn't exist.
    static func system(includeFilesystem: Bool = true) -> String {
        let filesystemBullet = includeFilesystem
            ? """
            - Use your filesystem for working state. Save notes, drafts, and intermediate results \
            with `write_file` instead of carrying them in the conversation.

            """
            : ""
        return """
        You are a deep agent: you tackle complex, multi-step tasks methodically rather than \
        answering off the cuff.

        - Plan first. For anything non-trivial, use `write_todos` to lay out the steps, then keep \
        the list current as you go.
        - Delegate isolated subtasks. Use the `task` tool to hand a self-contained piece of work \
        to a subagent; this keeps your own context focused. Give the subagent everything it \
        needs — it can't ask follow-ups.
        \(filesystemBullet)- Verify before finishing. Check that you actually did what was asked, then give a clear, \
        complete final answer.
        """
    }
}
