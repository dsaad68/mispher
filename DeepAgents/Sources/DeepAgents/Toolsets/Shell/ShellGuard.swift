import Foundation

/// Classifies a shell command before it runs. Mispher's port of the dangerous-command
/// handling in `langchain-ai/deepagents` (`config.py`: `DANGEROUS_SHELL_PATTERNS`,
/// `is_shell_command_allowed`), adapted for an **interactive** agent: because every shell
/// call is shown to the user behind the red approval card, command substitution / redirects /
/// `${}` are surfaced as ``riskMarkers(_:)`` rather than blocked (deepagents blocks those only
/// to stop allow-list bypass in its non-interactive mode). The hard block is reserved for the
/// genuinely catastrophic, irreversible, or privilege-escalating commands.
///
/// This is a **safety backstop, not a security boundary** - best-effort pattern matching can
/// be evaded by a determined adversary (and the segment split ignores quoting). The primary
/// control is the human-in-the-loop approval; the blocklist exists to stop the agent from a
/// catastrophic mistake the user might wave through.
public enum ShellGuard {
    /// What ``classify(_:)`` decides about a command.
    public enum Verdict: Sendable, Equatable {
        /// Refuse the command outright - it never runs, in any approval mode.
        case blocked(reason: String)
        /// Let it through to the human-in-the-loop approval card.
        case allowed
    }

    /// Classify `command`: ``Verdict/blocked(reason:)`` for anything in the four dangerous
    /// categories (privilege escalation, remote-pipe-to-shell, system control, catastrophic
    /// destruction), else ``Verdict/allowed``.
    public static func classify(_ command: String) -> Verdict {
        let normalized = normalize(command)
        guard !normalized.isEmpty else { return .allowed }

        // Whole-command patterns (they span a pipeline, so they're checked before the split):
        // a download piped into a shell, a fork bomb, redirection onto a block device, and a
        // signal sent to every process.
        if matches(normalized, remoteExecPatterns) {
            return .blocked(reason: "piping a download straight into a shell is not permitted.")
        }
        if matches(normalized, [forkBombPattern]) {
            return .blocked(reason: "this looks like a fork bomb.")
        }
        if matches(normalized, [blockDeviceRedirectPattern]) {
            return .blocked(reason: "redirecting output onto a disk device is not permitted.")
        }
        if matches(normalized, [killEveryProcessPattern]) {
            return .blocked(reason: "signalling every process is not permitted.")
        }

        // Unwrap `bash -c "<payload>"` so a dangerous command can't hide inside a quoted -c
        // string (the segment split can't see into the quotes).
        if let payload = shellDashCPayload(normalized), payload != normalized,
           case .blocked(let reason) = classify(payload) {
            return .blocked(reason: reason)
        }

        // Per-segment checks on each pipeline stage's executable and its arguments.
        for segment in segments(normalized) {
            let tokens = tokenize(segment)
            guard let executable = tokens.first.map(commandName) else { continue }
            if let reason = blockReason(executable: executable.lowercased(), args: Array(tokens.dropFirst())) {
                return .blocked(reason: reason)
            }
        }
        return .allowed
    }

    /// Human-readable risk notes for a command, shown on the approval card. These never block -
    /// they tell the user *why* the command warrants a careful look (deepagents'
    /// `DANGEROUS_SHELL_PATTERNS`, surfaced rather than enforced).
    public static func riskMarkers(_ command: String) -> [String] {
        var markers: [String] = []
        if command.contains("$(") || command.contains("`") { markers.append("command substitution") }
        if command.contains("${") { markers.append("variable expansion ${...}") }
        if command.contains(">") { markers.append("output redirection (>)") }
        if command.contains("<(") || command.contains(">(") { markers.append("process substitution") }
        if command.range(of: #"(?<!&)&(?!&)"#, options: .regularExpression) != nil {
            markers.append("background execution (&)")
        }
        if command.contains("*") || command.contains("?") { markers.append("wildcard glob") }
        if command.range(of: #"\b(curl|wget|ssh|scp|nc|telnet)\b"#, options: caseless) != nil {
            markers.append("network access")
        }
        if command.range(
            of: #"\b(brew|npm|pip3?|gem|cargo|apt|apt-get|yum|dnf|pacman)\s+(install|add)\b"#,
            options: caseless
        ) != nil {
            markers.append("installs software")
        }
        return markers
    }

    // MARK: - Per-segment blocking

    /// The reason `executable` (lower-cased basename) with `args` is blocked, or nil to allow.
    private static func blockReason(executable: String, args: [String]) -> String? {
        // 1. Privilege escalation.
        if ["sudo", "su", "doas"].contains(executable) {
            return "privilege escalation (\(executable)) is not permitted."
        }
        // 3. System control (kill is handled as a whole-command pattern).
        if ["shutdown", "reboot", "halt", "poweroff"].contains(executable) {
            return "shutting down or restarting the machine is not permitted."
        }
        // 4. Catastrophic destruction.
        if executable == "rm" { return rmBlockReason(args) }
        if executable == "dd", args.contains(where: { $0.lowercased().hasPrefix("of=/dev/") }) {
            return "writing to a disk device with dd is not permitted."
        }
        if executable == "mkfs" || executable.hasPrefix("mkfs.") || executable == "newfs" {
            return "formatting a filesystem is not permitted."
        }
        if executable == "diskutil", args.contains(where: { diskutilDestructive.contains($0.lowercased()) }) {
            return "erasing or repartitioning a disk is not permitted."
        }
        if ["fdisk", "parted", "gpt", "gparted", "sgdisk"].contains(executable) {
            return "editing disk partitions is not permitted."
        }
        if executable == "chmod" || executable == "chown",
           hasRecursiveFlag(args), targetsProtectedRoot(args) {
            return "recursively changing a system path's permissions or ownership is not permitted."
        }
        if executable == "find" { return findBlockReason(args) }
        return nil
    }

    /// `find` is blocked only when it traverses a **system root** (not the workspace) and either
    /// deletes (`-delete`) or `-exec`s a destructive command - e.g. `find / -exec rm -rf {} \;`.
    /// A filtered cleanup like `find . -name '*.o' -delete` is left to the approval card, since
    /// `find`'s deletes are almost always scoped by a predicate.
    private static func findBlockReason(_ args: [String]) -> String? {
        // Search paths are the leading args, before the first predicate / expression token.
        let searchPaths = args.prefix { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" }
        guard searchPaths.contains(where: pathIsSystemRoot) else { return nil }
        if args.contains("-delete") { return "find -delete over a system path is not permitted." }
        if let exec = args.firstIndex(where: { $0 == "-exec" || $0 == "-execdir" }), exec + 1 < args.count,
           destructiveCommands.contains(commandName(args[exec + 1]).lowercased()) {
            return "find -exec of a destructive command over a system path is not permitted."
        }
        return nil
    }

    private static let destructiveCommands: Set<String> = ["rm", "rmdir", "unlink", "shred", "dd", "mkfs"]

    /// `rm` is blocked only when it is both recursive **and** forced against a protected root
    /// (or uses `--no-preserve-root`). A recursive delete of a project subfolder is fine - it
    /// still goes through the red approval card.
    private static func rmBlockReason(_ args: [String]) -> String? {
        let flags = args.filter { $0.hasPrefix("-") }
        if flags.contains("--no-preserve-root") { return "rm --no-preserve-root is not permitted." }
        let recursive = flags.contains { $0 == "--recursive" || (isShortFlag($0) && hasLetter($0, "r")) }
        let force = flags.contains { $0 == "--force" || (isShortFlag($0) && $0.contains("f")) }
        guard recursive, force, targetsProtectedRoot(args) else { return nil }
        return "recursively force-deleting a protected path is not permitted."
    }

    private static func hasRecursiveFlag(_ args: [String]) -> Bool {
        args.contains { $0 == "--recursive" || (isShortFlag($0) && hasLetter($0, "r")) }
    }

    /// True when any non-flag argument names a filesystem root, the home folder, a top-level
    /// system directory, or a bare wildcard / current directory - the targets whose recursive
    /// deletion is catastrophic.
    private static func targetsProtectedRoot(_ args: [String]) -> Bool {
        args.contains { !$0.hasPrefix("-") && pathIsProtected($0) }
    }

    /// True when `arg` names a protected root - a filesystem root, a top-level system directory,
    /// the home folder **itself**, or a workspace-wiping form (`*`, `.`, `/*`). A subpath under
    /// home (`~/project`) is deliberately not protected: deleting it is normal work that just
    /// needs the approval card.
    private static func pathIsProtected(_ arg: String) -> Bool { matchesRoot(arg, protectedRoots) }

    /// Like ``pathIsProtected(_:)`` but only the real system roots and home - not the workspace
    /// wildcard / current-dir forms. Used for `find`, whose deletes are almost always filtered,
    /// so only a system-root traversal is catastrophic enough to refuse outright.
    private static func pathIsSystemRoot(_ arg: String) -> Bool { matchesRoot(arg, systemRoots) }

    private static func matchesRoot(_ arg: String, _ roots: Set<String>) -> Bool {
        var target = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if target.count > 1, target.hasSuffix("/") { target.removeLast() }
        if target == "~" || target == "$HOME" { return true }
        return roots.contains(target.lowercased())
    }

    private static let systemRoots: Set<String> = [
        "/", "/system", "/usr", "/bin", "/sbin", "/etc", "/var", "/users",
        "/library", "/opt", "/private", "/applications", "/cores"
    ]

    /// `rm`/`chmod` also guard the workspace-wiping forms (bare `*`, `.`, `/*`, …) - the project
    /// chose to hard-block whole-folder deletes, not just system paths.
    private static let protectedRoots: Set<String> = systemRoots.union([
        "/*", "*", ".", "..", "/system/*", "/usr/*", "/users/*", "/library/*"
    ])

    private static let diskutilDestructive: Set<String> = [
        "erasedisk", "erasevolume", "reformat", "partitiondisk",
        "zerodisk", "randomdisk", "secureerase", "splitpartition"
    ]

    // MARK: - Whole-command patterns

    /// A downloader piped straight into a shell, or a shell evaluating a download - the classic
    /// `curl … | sh` supply-chain footgun where the reviewer can't see what actually runs.
    private static let remoteExecPatterns = [
        #"\b(curl|wget|fetch)\b[^|;&]*\|\s*(sudo\s+)?(sh|bash|zsh|dash|ksh|fish|ash)\b"#,
        #"\b(sh|bash|zsh|dash|ksh)\b[^\n]*\$\(\s*(curl|wget|fetch)\b"#,
        #"\beval\b[^\n]*\b(curl|wget|fetch)\b"#,
        #"(source|\.)\s+<\(\s*(curl|wget|fetch)\b"#
    ]

    /// `:(){ :|:& };:` and whitespace variants - a function that recursively forks itself.
    private static let forkBombPattern = #"[\w:]*\(\)\s*\{[^}]*\|[^}]*&[^}]*\}\s*;"#

    /// Redirecting onto a raw block device (`> /dev/disk2`), which overwrites the disk.
    private static let blockDeviceRedirectPattern = #">\s*/dev/(disk|rdisk|sd[a-z]|hd[a-z]|nvme)"#

    /// `kill -1` / `kill -9 -1` with no following PID - signals every process the user owns.
    private static let killEveryProcessPattern = #"\bkill\s+(-\w+\s+)*-1\s*$"#

    // MARK: - Normalization & tokenizing

    /// Fold line continuations and runs of whitespace so the patterns see one clean line.
    private static func normalize(_ command: String) -> String {
        var s = command.replacingOccurrences(of: "\\\n", with: " ")
        for whitespace in ["\n", "\r", "\t"] { s = s.replacingOccurrences(of: whitespace, with: " ") }
        s = s.replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Split a normalized command into pipeline / sequence stages on `| || && ; &`. Best-effort:
    /// it does not honor quoting, which is fine for a backstop that errs toward catching more.
    private static func segments(_ command: String) -> [String] {
        var s = command
        for op in ["&&", "||"] { s = s.replacingOccurrences(of: op, with: ";") }
        for op in ["|", "&"] { s = s.replacingOccurrences(of: op, with: ";") }
        return s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Tokenize a segment and strip leading `VAR=val` assignments and transparent wrappers
    /// (`env`, `command`, `nohup`, `time`, …) so the first token is the real executable.
    private static func tokenize(_ segment: String) -> [String] {
        var tokens = segment.split(separator: " ").map(String.init)
        while let first = tokens.first {
            if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                tokens.removeFirst()
                continue
            }
            if wrapperCommands.contains(commandName(first).lowercased()) {
                tokens.removeFirst()
                continue
            }
            break
        }
        return tokens
    }

    private static let wrapperCommands: Set<String> = ["command", "env", "nohup", "time", "builtin", "exec", "\\"]

    /// The basename of a command token (`/bin/rm` -> `rm`).
    private static func commandName(_ token: String) -> String {
        token.split(separator: "/").last.map(String.init) ?? token
    }

    /// If `command` invokes a shell with `-c`, the (de-quoted) payload that shell would run, so
    /// ``classify(_:)`` can recurse into it. Returns nil when there's no shell `-c` to unwrap.
    private static func shellDashCPayload(_ command: String) -> String? {
        guard command.range(of: #"\b(sh|bash|zsh|dash|ksh|ash)\b"#, options: caseless) != nil,
              let marker = command.range(of: #"\s-c\s+"#, options: .regularExpression)
        else { return nil }
        var payload = String(command[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where payload.hasPrefix(quote) {
            payload.removeFirst()
            if payload.hasSuffix(quote) { payload.removeLast() }
            break
        }
        return payload.isEmpty ? nil : payload
    }

    // MARK: - Helpers

    private static let caseless: String.CompareOptions = [.regularExpression, .caseInsensitive]

    private static func matches(_ command: String, _ patterns: [String]) -> Bool {
        patterns.contains { command.range(of: $0, options: caseless) != nil }
    }

    private static func isShortFlag(_ flag: String) -> Bool { flag.hasPrefix("-") && !flag.hasPrefix("--") }

    private static func hasLetter(_ flag: String, _ letter: Character) -> Bool {
        flag.lowercased().contains(letter)
    }
}
