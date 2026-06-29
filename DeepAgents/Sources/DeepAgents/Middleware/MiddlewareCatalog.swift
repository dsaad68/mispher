import Foundation

/// One tool a capability middleware contributes, described for the Settings UI and for the
/// default approval policy. `name` is the agent's dispatch name (e.g. `write_clipboard`) — the
/// same string the model calls and ``AgentToolPolicy`` keys on.
public struct ToolDescriptor: Sendable, Identifiable, Hashable {
    public let name: String
    public let displayName: String
    public let summary: String
    /// The approval the agent uses when the user hasn't overridden it. Reads are `approve`;
    /// writes / outward-facing actions default to `ask`, matching the deep agent's existing
    /// file/notes gating.
    public let defaultApproval: ToolApprovalMode

    public var id: String { name }

    public init(
        name: String, displayName: String, summary: String,
        defaultApproval: ToolApprovalMode = .approve
    ) {
        self.name = name
        self.displayName = displayName
        self.summary = summary
        self.defaultApproval = defaultApproval
    }
}

/// One capability middleware the user can turn on/off and tune per tool. `id` is the
/// middleware's own ``AgentMiddleware/name`` (e.g. `clipboard`), so a descriptor maps straight
/// onto the running middleware it represents.
public struct MiddlewareDescriptor: Sendable, Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let systemImage: String
    public let tools: [ToolDescriptor]

    public init(
        id: String, displayName: String, summary: String, systemImage: String,
        tools: [ToolDescriptor]
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.systemImage = systemImage
        self.tools = tools
    }
}

/// The catalog of capability middleware the deep agent exposes to the user, the single source
/// of truth for the Middleware Settings tab and for default per-tool approvals. Only
/// **capability** middleware appear here; the agent's scaffolding (planning todos, subagents)
/// is always on and not user-toggleable, and MCP is configured in its own Settings tab.
///
/// Each `id` matches the corresponding middleware's ``AgentMiddleware/name`` so
/// ``AgentToolPolicy`` can disable a middleware by name and the deep-agent factory can drop it.
public enum MiddlewareCatalog {
    public static let screenshot = MiddlewareDescriptor(
        id: "screenshot",
        displayName: "Screenshot",
        summary: "Capture the screen or a specific window so the vision subagent can read it.",
        systemImage: "camera.viewfinder",
        tools: [
            ToolDescriptor(
                name: "take_screenshot", displayName: "Take screenshot",
                summary: "Capture the full screen."
            ),
            ToolDescriptor(
                name: "take_window_screenshots", displayName: "Take window screenshots",
                summary: "Capture each open window separately."
            )
        ]
    )

    public static let clipboard = MiddlewareDescriptor(
        id: "clipboard",
        displayName: "Clipboard",
        summary: "Read from and write to the system pasteboard.",
        systemImage: "doc.on.clipboard",
        tools: [
            ToolDescriptor(
                name: "read_clipboard", displayName: "Read clipboard",
                summary: "Read the current pasteboard contents."
            ),
            ToolDescriptor(
                name: "write_clipboard", displayName: "Write clipboard",
                summary: "Replace the pasteboard contents."
            )
        ]
    )

    public static let appleNotes = MiddlewareDescriptor(
        id: "apple_notes",
        displayName: "Apple Notes",
        summary: "List, read, create, and update notes in Apple Notes.",
        systemImage: "note.text",
        tools: [
            ToolDescriptor(
                name: "list_notes", displayName: "List notes",
                summary: "List available notes."
            ),
            ToolDescriptor(
                name: "read_note", displayName: "Read note",
                summary: "Read a note's contents."
            ),
            ToolDescriptor(
                name: "create_note", displayName: "Create note",
                summary: "Create a new note.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "update_note", displayName: "Update note",
                summary: "Modify an existing note.", defaultApproval: .ask
            )
        ]
    )

    public static let filesystem = MiddlewareDescriptor(
        id: "filesystem",
        displayName: "Files",
        summary: "List, read, write, and edit files on your disk (rooted at the working folder).",
        systemImage: "folder",
        tools: [
            ToolDescriptor(
                name: "ls", displayName: "List files",
                summary: "List files and folders.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "read_file", displayName: "Read file",
                summary: "Read a file's contents.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "write_file", displayName: "Write file",
                summary: "Create or overwrite a file.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "edit_file", displayName: "Edit file",
                summary: "Replace an exact snippet in a file.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "mkdir", displayName: "Make folder",
                summary: "Create a new folder.", defaultApproval: .ask
            )
        ]
    )

    public static let web = MiddlewareDescriptor(
        id: "web",
        displayName: "Web",
        summary: "Fetch web pages as text and make raw HTTP requests.",
        systemImage: "globe",
        tools: [
            ToolDescriptor(
                name: "fetch", displayName: "Fetch URL",
                summary: "Fetch a URL and return readable text.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "curl", displayName: "HTTP request",
                summary: "Make an HTTP request and see the status, headers, and body.", defaultApproval: .ask
            )
        ]
    )

    public static let search = MiddlewareDescriptor(
        id: "search",
        displayName: "Search",
        summary: "Search file contents and find files in the working folder.",
        systemImage: "magnifyingglass",
        tools: [
            ToolDescriptor(
                name: "grep", displayName: "Search contents",
                summary: "Search file contents by regular expression.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "glob", displayName: "Find files",
                summary: "Find files whose path matches a glob.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "tree", displayName: "Folder tree",
                summary: "Show the folder layout as a tree.", defaultApproval: .ask
            )
        ]
    )

    public static let text = MiddlewareDescriptor(
        id: "text",
        displayName: "Text tools",
        summary: "Peek at the start/end of files and compare two files.",
        systemImage: "doc.text.magnifyingglass",
        tools: [
            ToolDescriptor(
                name: "head", displayName: "Head",
                summary: "Show the first lines of a file.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "tail", displayName: "Tail",
                summary: "Show the last lines of a file.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "diff", displayName: "Diff",
                summary: "Compare two files.", defaultApproval: .ask
            )
        ]
    )

    public static let git = MiddlewareDescriptor(
        id: "git",
        displayName: "Git",
        summary: "Read-only git inspection of the working folder's repository.",
        systemImage: "arrow.triangle.branch",
        tools: [
            ToolDescriptor(name: "git_status", displayName: "Git status", summary: "Show working-tree status."),
            ToolDescriptor(name: "git_diff", displayName: "Git diff", summary: "Show changes as a diff."),
            ToolDescriptor(name: "git_log", displayName: "Git log", summary: "Show recent commits."),
            ToolDescriptor(name: "git_show", displayName: "Git show", summary: "Show one commit."),
            ToolDescriptor(name: "git_blame", displayName: "Git blame", summary: "Show line-by-line authorship.")
        ]
    )

    public static let macos = MiddlewareDescriptor(
        id: "macos",
        displayName: "System",
        summary: "Spotlight search, open files/apps, download, speak, and notify.",
        systemImage: "macwindow",
        tools: [
            ToolDescriptor(
                name: "mdfind", displayName: "Spotlight",
                summary: "Find files anywhere on the Mac.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "open", displayName: "Open",
                summary: "Open a file or URL in its default app.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "open_app", displayName: "Open app",
                summary: "Launch an app, optionally with a file or URL.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "download", displayName: "Download",
                summary: "Save a URL to a file in the working folder.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "say", displayName: "Say",
                summary: "Speak text aloud.", defaultApproval: .ask
            ),
            ToolDescriptor(
                name: "notify", displayName: "Notify",
                summary: "Post a notification.", defaultApproval: .ask
            )
        ]
    )

    public static let shell = MiddlewareDescriptor(
        id: "shell",
        displayName: "Shell",
        summary: "Run shell commands in the working folder. Catastrophic commands are always blocked.",
        systemImage: "terminal",
        tools: [
            ToolDescriptor(
                name: "shell", displayName: "Run shell command",
                summary: "Run a shell command via /bin/sh -c. Always asks before running.",
                defaultApproval: .ask
            )
        ]
    )

    /// The Apple Container sandbox capability. Deliberately **not** in ``all``: unlike the binary
    /// on/off capabilities, it's opt-in and three-way (off / failover / container-only) via
    /// ``AgentToolPolicy/sandbox``, so it's surfaced by ripple's `/config` editor as a special row
    /// rather than the catalog-driven Settings toggles. Kept here as the source of its display text.
    public static let container = MiddlewareDescriptor(
        id: "container",
        displayName: "Container",
        summary: "Run shell commands inside an Apple Container sandbox with the working folder "
            + "mounted. Off by default - needs Apple's `container` tool installed.",
        systemImage: "shippingbox",
        tools: [
            ToolDescriptor(
                name: "container_shell", displayName: "Run command in container",
                summary: "Run a command inside the sandbox container (Linux, Python + uv). Always asks first.",
                defaultApproval: .ask
            )
        ]
    )

    /// All catalog-driven capability middleware, in display order (the binary on/off toggles). The
    /// container sandbox is excluded - see ``container``.
    public static let all: [MiddlewareDescriptor] = [
        screenshot, clipboard, appleNotes, filesystem, web, search, text, git, macos, shell
    ]

    /// Map of tool name → its catalog default approval, used when expanding a policy.
    public static var toolDefaults: [String: ToolApprovalMode] {
        var defaults: [String: ToolApprovalMode] = [:]
        for middleware in all {
            for tool in middleware.tools { defaults[tool.name] = tool.defaultApproval }
        }
        return defaults
    }

    /// The tool names contributed by `middlewareID`, or `[]` if it isn't a catalog middleware.
    public static func toolNames(forMiddleware middlewareID: String) -> [String] {
        all.first { $0.id == middlewareID }?.tools.map(\.name) ?? []
    }
}
