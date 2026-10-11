import { describe, expect, it } from "vitest";
import { Frontmatter } from "../src/frontmatter.ts";

const sample = `---
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
`;

describe("Frontmatter", () => {
  it("round-trips untouched documents byte for byte", () => {
    expect(Frontmatter.parse(sample).serialize()).toBe(sample);
  });

  it("round-trips CRLF files", () => {
    const crlf = sample.replace(/\n/g, "\r\n");
    expect(Frontmatter.parse(crlf).serialize()).toBe(crlf);
  });

  it("reads typed scalars and lists, ignoring trailing comments", () => {
    const doc = Frontmatter.parse(sample);
    expect(doc.get("id")).toBe(42);
    expect(doc.get("title")).toBe("Board TUI");
    expect(doc.get("status")).toBe("active");
    expect(doc.get("sessions")).toEqual(["8c1f", "a: b"]);
    expect(doc.get("missing")).toBeUndefined();
  });

  it("changes only the field it is told to change", () => {
    const doc = Frontmatter.parse(sample);
    doc.set("status", "review");
    const out = doc.serialize();
    expect(out).toBe(sample.replace("status: active  ", "status: review  "));
  });

  it("keeps unknown fields, comments and blocks when setting another field", () => {
    const doc = Frontmatter.parse(sample);
    doc.set("title", "New title");
    const out = doc.serialize();
    for (const keep of ["custom_block:\n  nested: 1\n  - list-ish", "# a comment line", "future_field: keep me"]) {
      expect(out).toContain(keep);
    }
  });

  it("appends new fields and removes fields set to undefined", () => {
    const doc = Frontmatter.parse(sample);
    doc.set("branch", "board-tui");
    doc.set("future_field", undefined);
    const out = doc.serialize();
    expect(out).toContain("branch: board-tui\n---");
    expect(out).not.toContain("future_field");
  });

  it("quotes values that would not parse back", () => {
    const doc = Frontmatter.parse("---\nid: 1\n---\n");
    for (const v of ["a: b", "#tag", "123", "true", "", " padded", "x # y"]) {
      doc.set("t", v);
      expect(Frontmatter.parse(doc.serialize()).get("t")).toBe(v);
    }
    doc.set("l", ["a, b", "c"]);
    expect(Frontmatter.parse(doc.serialize()).get("l")).toEqual(["a, b", "c"]);
  });

  it("handles files with no frontmatter", () => {
    const doc = Frontmatter.parse("just text\n");
    expect(doc.hasFrontmatter).toBe(false);
    expect(doc.serialize()).toBe("just text\n");
    doc.set("id", 1);
    expect(doc.serialize()).toBe("---\nid: 1\n---\njust text\n");
  });
});
