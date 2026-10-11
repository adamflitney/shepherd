import Testing
@testable import ShepherdTasks

private let sample = """
---
id: 42
title: Board TUI
status: active          # inbox | ready | active | review | done
sessions: [8c1f, "a: b"]
custom_block:
  nested: 1
  - list-ish
# a comment line

future_field: keep me
---

## Plan
- [x] one

## Log
- 2026-10-05 11:20: hi

"""

@Suite("Frontmatter")
struct FrontmatterTests {
    @Test func roundTripsUntouchedDocumentsByteForByte() {
        #expect(Frontmatter.parse(sample).serialize() == sample)
    }

    @Test func roundTripsCRLFFiles() {
        let crlf = sample.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(Frontmatter.parse(crlf).serialize() == crlf)
    }

    @Test func readsTypedScalarsAndListsIgnoringTrailingComments() {
        let doc = Frontmatter.parse(sample)
        #expect(doc.get("id") == .int(42))
        #expect(doc.get("title") == .string("Board TUI"))
        #expect(doc.get("status") == .string("active"))
        #expect(doc.get("sessions") == .list(["8c1f", "a: b"]))
        #expect(doc.get("missing") == nil)
    }

    @Test func changesOnlyTheFieldItIsToldToChange() {
        var doc = Frontmatter.parse(sample)
        doc.set("status", .string("review"))
        #expect(doc.serialize() == sample.replacingOccurrences(of: "status: active  ", with: "status: review  "))
    }

    @Test func keepsUnknownFieldsCommentsAndBlocksWhenSettingAnotherField() {
        var doc = Frontmatter.parse(sample)
        doc.set("title", .string("New title"))
        let out = doc.serialize()
        for keep in ["custom_block:\n  nested: 1\n  - list-ish", "# a comment line", "future_field: keep me"] {
            #expect(out.contains(keep))
        }
    }

    @Test func appendsNewFieldsAndRemovesFieldsSetToNil() {
        var doc = Frontmatter.parse(sample)
        doc.set("branch", .string("board-tui"))
        doc.set("future_field", nil)
        let out = doc.serialize()
        #expect(out.contains("branch: board-tui\n---"))
        #expect(!out.contains("future_field"))
    }

    @Test func quotesValuesThatWouldNotParseBack() {
        var doc = Frontmatter.parse("---\nid: 1\n---\n")
        for v in ["a: b", "#tag", "123", "true", "", " padded", "x # y", "say \"hi\"", "back\\slash", "multi\nline"] {
            doc.set("t", .string(v))
            #expect(Frontmatter.parse(doc.serialize()).get("t") == .string(v), "round trip of \(v.debugDescription)")
        }
        doc.set("l", .list(["a, b", "c"]))
        #expect(Frontmatter.parse(doc.serialize()).get("l") == .list(["a, b", "c"]))
    }

    @Test func handlesFilesWithNoFrontmatter() {
        var doc = Frontmatter.parse("just text\n")
        #expect(!doc.hasFrontmatter)
        #expect(doc.serialize() == "just text\n")
        doc.set("id", .int(1))
        #expect(doc.serialize() == "---\nid: 1\n---\njust text\n")
    }

    @Test func handlesEmptyFrontmatterAndAClosingFenceWithNoTrailingNewline() {
        #expect(Frontmatter.parse("---\n---\nbody\n").serialize() == "---\n---\nbody\n")
        let doc = Frontmatter.parse("---\na: 1\n---")
        #expect(doc.get("a") == .int(1))
        #expect(doc.body == "")
    }
}
