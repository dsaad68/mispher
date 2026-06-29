@testable import DeepAgents
import Testing

/// `FileDiff.compute` turns a before/after pair into added/removed counts and line-numbered hunks
/// (with surrounding context, long unchanged stretches dropped). These pin the counts, the line
/// numbering, the no-op case, and the hunk grouping.
struct FileDiffTests {
    @Test func singleLineReplaceCountsAndNumbers() {
        let before = "alpha\nbravo\ncharlie\ndelta\necho"
        let after = "alpha\nbravo\nCHANGED\ndelta\necho"
        let diff = FileDiff.compute(path: "f.txt", before: before, after: after)
        #expect(diff?.added == 1)
        #expect(diff?.removed == 1)
        #expect(diff?.path == "f.txt")

        // The whole file fits in one hunk; the change is a removed "charlie" then an added "CHANGED".
        let lines = diff?.hunks.first ?? []
        let removed = lines.first { $0.kind == .removed }
        let added = lines.first { $0.kind == .added }
        #expect(removed?.text == "charlie")
        #expect(removed?.oldNumber == 3)
        #expect(removed?.newNumber == nil)
        #expect(added?.text == "CHANGED")
        #expect(added?.newNumber == 3)
        #expect(added?.oldNumber == nil)
    }

    @Test func pureInsertion() {
        let diff = FileDiff.compute(path: "f", before: "a\nc", after: "a\nb\nc")
        #expect(diff?.added == 1)
        #expect(diff?.removed == 0)
        #expect(diff?.hunks.first?.contains { $0.kind == .added && $0.text == "b" } == true)
    }

    @Test func pureDeletion() {
        let diff = FileDiff.compute(path: "f", before: "a\nb\nc", after: "a\nc")
        #expect(diff?.added == 0)
        #expect(diff?.removed == 1)
        #expect(diff?.hunks.first?.contains { $0.kind == .removed && $0.text == "b" } == true)
    }

    @Test func midLineEditShowsAsRemovedPlusAdded() {
        // old_string need not be line-aligned; the changed line surfaces as one removed + one added.
        let diff = FileDiff.compute(path: "f", before: "let x = 1\n", after: "let x = 2\n")
        #expect(diff?.added == 1)
        #expect(diff?.removed == 1)
    }

    @Test func noChangeReturnsNil() {
        #expect(FileDiff.compute(path: "f", before: "a\nb\nc", after: "a\nb\nc") == nil)
    }

    @Test func trailingNewlineIsNotAPhantomLine() {
        // "a\nb\n" is two lines, not three - a final newline must not add an empty removed line.
        let diff = FileDiff.compute(path: "f", before: "a\nb\n", after: "a\nB\n")
        #expect(diff?.added == 1)
        #expect(diff?.removed == 1)
    }

    @Test func contextIsTrimmedAroundAnIsolatedChange() {
        let before = (1 ... 9).map { "l\($0)" }.joined(separator: "\n")
        let after = before.replacingOccurrences(of: "l5", with: "L5")
        let diff = FileDiff.compute(path: "f", before: before, after: after, context: 1)
        // One hunk: context l4, removed l5, added L5, context l6 - the rest is dropped.
        #expect(diff?.hunks.count == 1)
        let texts = diff?.hunks.first?.map(\.text)
        #expect(texts == ["l4", "l5", "L5", "l6"])
    }

    @Test func twoSeparateChangesProduceTwoHunks() {
        let before = (1 ... 9).map { "l\($0)" }.joined(separator: "\n")
        let after = before
            .replacingOccurrences(of: "l2", with: "L2")
            .replacingOccurrences(of: "l8", with: "L8")
        let diff = FileDiff.compute(path: "f", before: before, after: after, context: 1)
        #expect(diff?.hunks.count == 2)
        #expect(diff?.added == 2)
        #expect(diff?.removed == 2)
    }
}
