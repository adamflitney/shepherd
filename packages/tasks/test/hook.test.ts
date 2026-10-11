import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import { sessionStart } from "../src/hook.ts";
import { TaskStore } from "../src/store.ts";
import { taskContext } from "../src/task.ts";

const NOW = new Date("2026-10-11T09:30:00");
let store: TaskStore;
beforeEach(() => {
  store = new TaskStore(mkdtempSync(join(tmpdir(), "crook-hook-")));
});
const ctx = (out: object | undefined) => (out as { hookSpecificOutput: { additionalContext: string } }).hookSpecificOutput.additionalContext;

describe("sessionStart", () => {
  it("injects the plan and log of the linked task", () => {
    const t = store.create({ title: "Board", objective: "ship it" }, NOW);
    store.update(t.id, (x) => {
      x.addPlanItem("do a");
      x.appendLog("did b", NOW);
      x.linkSession("s1");
    });
    const text = ctx(sessionStart({ session_id: "s1", source: "resume" }, {}, store));
    expect(text).toContain("task #1: Board");
    expect(text).toContain("- [ ] do a");
    expect(text).toContain("did b");
  });

  it("does nothing for unlinked sessions", () => {
    store.create({ title: "Board" }, NOW);
    expect(sessionStart({ session_id: "zzz" }, {}, store)).toBeUndefined();
    expect(sessionStart({}, {}, store)).toBeUndefined();
  });

  it("links a session started for a task via SHEPHERD_TASK_ID, including after /clear", () => {
    store.create({ title: "Board" }, NOW);
    expect(sessionStart({ session_id: "first" }, { SHEPHERD_TASK_ID: "1" }, store)).toBeDefined();
    expect(sessionStart({ session_id: "after-clear", source: "clear" }, { SHEPHERD_TASK_ID: "1" }, store)).toBeDefined();
    expect(store.get(1)?.sessions).toEqual(["first", "after-clear"]);
  });

  it("ignores a SHEPHERD_TASK_ID that does not exist", () => {
    expect(sessionStart({ session_id: "s" }, { SHEPHERD_TASK_ID: "99" }, store)).toBeUndefined();
  });
});

describe("taskContext", () => {
  it("stays under the limit, keeping the plan and the newest log lines", () => {
    const t = store.create({ title: "Big" }, NOW);
    store.update(t.id, (x) => {
      x.addPlanItem("the plan");
      for (let i = 0; i < 500; i++) x.appendLog(`entry number ${i}`, NOW);
    });
    const text = taskContext(store.get(1)!, 2000);
    expect(text.length).toBeLessThanOrEqual(2000);
    expect(text).toContain("the plan");
    expect(text).toContain("entry number 499");
    expect(text).not.toContain("entry number 0\n");
    expect(text).toContain("(most recent)");
  });
});
