import Foundation

/// A line-level diff of a single file edit, computed by ``EditFileTool`` after it applies a
/// change so the UI can show *what* changed (added / removed lines with surrounding context)
/// instead of just the short "Edited …" text the model sees. UI-only: the model's tool
/// result stays the same short string, so this adds no tokens to the conversation.
///
/// The diff is grouped into ``hunks`` - contiguous runs of changed lines plus a few unchanged
/// lines of context on each side - with the long unchanged stretches between hunks dropped, so
/// a one-line edit in a thousand-line file renders a handful of rows, not the whole file.
public struct FileDiff: Sendable, Equatable {
    /// Whether a rendered line was unchanged, added, or removed.
    public enum LineKind: Sendable, Equatable { case context, added, removed }

    /// One rendered diff line. `oldNumber` is its 1-based line in the *before* file (nil for an
    /// added line), `newNumber` its 1-based line in the *after* file (nil for a removed line);
    /// a context line carries both.
    public struct Line: Sendable, Equatable {
        public let kind: LineKind
        public let oldNumber: Int?
        public let newNumber: Int?
        public let text: String

        public init(kind: LineKind, oldNumber: Int?, newNumber: Int?, text: String) {
            self.kind = kind
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.text = text
        }
    }

    /// The edited file's path, exactly as the model passed it to the tool.
    public let path: String
    /// How many lines were added (green `+`) and removed (red `-`) across the whole edit.
    public let added: Int
    public let removed: Int
    /// The changed regions, each a contiguous run of context + changed lines.
    public let hunks: [[Line]]

    public init(path: String, added: Int, removed: Int, hunks: [[Line]]) {
        self.path = path
        self.added = added
        self.removed = removed
        self.hunks = hunks
    }

    /// Compute the line diff between `before` and `after`, keeping up to `context` unchanged
    /// lines of context around each change. Returns `nil` when nothing changed, so a no-op edit
    /// shows nothing special. Uses the standard library's Myers diff
    /// (`CollectionDifference`) - no third-party dependency.
    public static func compute(path: String, before: String, after: String, context: Int = 3) -> FileDiff? {
        let beforeLines = splitLines(before)
        let afterLines = splitLines(after)

        // Removal offsets index into `before`; insertion offsets index into `after`.
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in afterLines.difference(from: beforeLines) {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }
        guard !removedOffsets.isEmpty || !insertedOffsets.isEmpty else { return nil }

        // Walk both files in lockstep, emitting removals before additions at a given position,
        // to reconstruct one merged, line-numbered timeline of the change.
        var merged: [Line] = []
        var i = 0, j = 0
        while i < beforeLines.count || j < afterLines.count {
            if i < beforeLines.count, removedOffsets.contains(i) {
                merged.append(Line(kind: .removed, oldNumber: i + 1, newNumber: nil, text: beforeLines[i]))
                i += 1
            } else if j < afterLines.count, insertedOffsets.contains(j) {
                merged.append(Line(kind: .added, oldNumber: nil, newNumber: j + 1, text: afterLines[j]))
                j += 1
            } else if i < beforeLines.count, j < afterLines.count {
                merged.append(Line(kind: .context, oldNumber: i + 1, newNumber: j + 1, text: beforeLines[i]))
                i += 1
                j += 1
            } else if i < beforeLines.count {
                merged.append(Line(kind: .removed, oldNumber: i + 1, newNumber: nil, text: beforeLines[i]))
                i += 1
            } else {
                merged.append(Line(kind: .added, oldNumber: nil, newNumber: j + 1, text: afterLines[j]))
                j += 1
            }
        }

        let added = merged.reduce(0) { $0 + ($1.kind == .added ? 1 : 0) }
        let removed = merged.reduce(0) { $0 + ($1.kind == .removed ? 1 : 0) }
        return FileDiff(path: path, added: added, removed: removed, hunks: hunks(from: merged, context: context))
    }

    /// Keep each changed line plus `context` neighbours on either side, then split the kept
    /// lines into hunks wherever a gap (a dropped unchanged stretch) falls between them.
    private static func hunks(from merged: [Line], context: Int) -> [[Line]] {
        var keep = Set<Int>()
        for index in merged.indices where merged[index].kind != .context {
            for k in max(0, index - context) ... min(merged.count - 1, index + context) { keep.insert(k) }
        }
        var hunks: [[Line]] = []
        var current: [Line] = []
        var previous: Int?
        for index in merged.indices where keep.contains(index) {
            if let previous, index != previous + 1, !current.isEmpty {
                hunks.append(current)
                current = []
            }
            current.append(merged[index])
            previous = index
        }
        if !current.isEmpty { hunks.append(current) }
        return hunks
    }

    /// Split into lines on "\n", dropping a single trailing empty element when the content ends
    /// in a newline (so a file ending "…\n" doesn't render a phantom blank last line), and
    /// treating an empty string as zero lines.
    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }
}

/// The agent-state convention for a file edit's diff in flight, mirroring ``ScreenshotState``:
/// ``EditFileTool`` stashes a ``FileDiff`` under ``pendingKey`` in its `ToolOutput.stateUpdate`,
/// and `ReactAgent` reads it back in `dispatchTool` to surface it on the `.toolCompleted`
/// event so the UI can render a diff card.
public enum EditDiffState {
    public static let pendingKey = "pending_edit_diff"
}
