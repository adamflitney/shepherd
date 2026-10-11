import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import { TaskStore } from "../src/store.ts";
import { Task } from "../src/task.ts";

const NOW = new Date("2026-10-11T09:30:00");

describe("Task", () => {
  it("appends log entries under ## Log and creates the section if missing", () => {
    const t = Task.parse("---\nid: 1\ntitle: T\n---\n\n## Plan\n- [ ] a\n");
    t.appendLog("started", NOW);
    expect(t.serialize()).toBe(
      "---\nid: 1\ntitle: T\nupdated: 2026-10-11T09:30:00\n---\n\n## Plan\n- [ ] a\n\n## Log\n- 2026-10-11 09:30: started\n",
    );
    t.appendLog("more", NOW);
    expect(t.serialize()).toContain("- 2026-10-11 09:30: started\n- 2026-10-11 09:30: more\n");
  });

  it("keeps text after the log section's last entry in order", () => {
    const t = Task.parse("---\nid: 1\n---\n## Log\n- old\n\n## Notes\nkeep\n");
    t.appendLog("new", NOW);
    expect(t.body).toBe("## Log\n- old\n- 2026-10-11 09:30: new\n\n## Notes\nkeep\n");
  });

  it("links sessions once and unlinks them", () => {
    const t = Task.parse("---\nid: 1\nsessions: [a]\n---\n");
    t.linkSession("b");
    t.linkSession("b");
    expect(t.sessions).toEqual(["a", "b"]);
    t.unlinkSession("a");
    expect(t.sessions).toEqual(["b"]);
  });

  it("adds and checks plan items", () => {
    const t = Task.parse("---\nid: 1\n---\n");
    t.addPlanItem("first");
    t.addPlanItem("second");
    t.setPlanItem(2, true);
    expect(t.body).toBe("## Plan\n- [ ] first\n- [x] second\n");
    expect(t.progress).toEqual({ done: 1, total: 2 });
  });

  it("rejects an unknown status", () => {
    const t = Task.parse("---\nid: 1\n---\n");
    expect(() => t.setStatus("nope" as never)).toThrow(/status/);
  });
});

describe("TaskStore", () => {
  let dir: string;
  let store: TaskStore;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "crook-"));
    store = new TaskStore(dir);
  });

  it("creates tasks with sequential ids and slugged filenames", () => {
    const a = store.create({ title: "Board TUI!", projectPath: "/p" }, NOW);
    const b = store.create({ title: "Second one" }, NOW);
    expect([a.id, b.id]).toEqual([1, 2]);
    expect(readdirSync(dir).sort()).toEqual(["0001-board-tui.md", "0002-second-one.md"]);
  });

  it("gets by id and lists in id order, skipping non-task files", () => {
    store.create({ title: "a" }, NOW);
    store.create({ title: "b" }, NOW);
    writeFileSync(join(dir, "README.md"), "hi");
    expect(store.list().map((t) => t.title)).toEqual(["a", "b"]);
    expect(store.get(2)?.title).toBe("b");
    expect(store.get(9)).toBeUndefined();
  });

  it("update re-reads the file, so concurrent edits to other fields survive", () => {
    const t = store.create({ title: "a" }, NOW);
    const file = join(dir, "0001-a.md");
    store.update(t.id, (x) => x.linkSession("s1"), NOW);
    // someone hand-edits the file between our read and write
    writeFileSync(file, readFileSync(file, "utf8").replace("title: a", "title: a\nnew_field: x"));
    store.update(t.id, (x) => x.setStatus("active"), NOW);
    const text = readFileSync(file, "utf8");
    expect(text).toContain("new_field: x");
    expect(text).toContain("status: active");
    expect(text).toContain("sessions: [s1]");
  });

  it("finds tasks by linked session id", () => {
    store.create({ title: "a" }, NOW);
    const b = store.create({ title: "b" }, NOW);
    store.update(b.id, (x) => x.linkSession("sess-9"), NOW);
    expect(store.findBySession("sess-9")?.id).toBe(2);
    expect(store.findBySession("nope")).toBeUndefined();
  });
});
