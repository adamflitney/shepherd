import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TaskStore } from "@shepherd/tasks";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { SessionManager } from "../src/manager.ts";
import { fakeAgent, waitFor } from "./helpers.ts";

let manager: SessionManager;
let store: TaskStore;
let resumable: Set<string>;
let work: string;

beforeEach(() => {
  work = mkdtempSync(join(tmpdir(), "shep-work-"));
  store = new TaskStore(mkdtempSync(join(tmpdir(), "shep-tasks-")));
  resumable = new Set();
  manager = new SessionManager({ store, agent: fakeAgent(resumable), env: { PATH: process.env.PATH, SHEPHERD_TASK_ID: "stale", CLAUDE_CODE_CHILD_SESSION: "1", CLAUDE_CODE_USE_BEDROCK: "1" } });
});
afterEach(() => manager.shutdown());

describe("SessionManager", () => {
  it("runs the agent in the given directory and tracks what is on screen", async () => {
    const info = manager.create({ cwd: work });
    const s = manager.get(info.id);
    await waitFor(() => s.peek().includes("ARGS: --session-id"), "agent output");
    expect(s.peek()).toContain(`--session-id ${info.id}`);
    expect(s.peek()).toContain(`SESSION=${info.id}`);
    expect(s.peek()).toContain("TASK= "); // a stale SHEPHERD_TASK_ID in the daemon's env must not leak
    expect(info.title).toBe(work.split("/").at(-1));
  });

  it("does not pass Claude Code's own session variables on, but keeps user config", async () => {
    const s = manager.get(manager.create({ cwd: work }).id);
    await waitFor(() => s.peek().includes("ARGS:"), "agent output");
    s.write("env | grep CLAUDE\r");
    await waitFor(() => s.peek().includes("CLAUDE_CODE_USE_BEDROCK=1"), "env listing");
    expect(s.peek()).not.toContain("CHILD_SESSION=");
  });

  it("forwards input and reports output to listeners", async () => {
    const s = manager.get(manager.create({ cwd: work }).id);
    let got = "";
    s.onData((d) => (got += d));
    s.write("hello there\r");
    await waitFor(() => got.includes("hello there"), "echoed input");
    expect(s.peek()).toContain("hello there");
  });

  it("starts a task session: links it first, sets the env, defaults cwd and prompt", async () => {
    const t = store.create({ title: "Board", projectPath: work });
    const info = manager.create({ taskId: t.id });
    expect(info.cwd).toBe(work);
    expect(info.taskId).toBe(t.id);
    expect(store.get(t.id)?.sessions).toEqual([info.id]);
    const s = manager.get(info.id);
    await waitFor(() => s.peek().includes("TASK=1"), "task env");
    expect(s.peek()).toContain("Start on the task described in your session context.");
  });

  it("resumes the task's latest conversation instead of starting a new one", async () => {
    const t = store.create({ title: "Board", projectPath: work });
    const first = manager.create({ taskId: t.id });
    manager.get(first.id).kill();
    await waitFor(() => manager.get(first.id).status === "exited", "exit");
    manager.remove(first.id);
    resumable.add(first.id);

    const again = manager.create({ taskId: t.id });
    expect(again.id).toBe(first.id);
    expect(store.get(t.id)?.sessions).toEqual([first.id]); // no second link
    await waitFor(() => manager.get(again.id).peek().includes("--resume"), "resume args");
  });

  it("starts a new conversation when the old one has no transcript", () => {
    const t = store.create({ title: "Board", projectPath: work });
    const first = manager.create({ taskId: t.id });
    manager.get(first.id).kill();
    const second = manager.create({ taskId: t.id });
    expect(second.id).not.toBe(first.id);
    expect(store.get(t.id)?.sessions).toEqual([first.id, second.id]);
  });

  it("rejects unknown tasks and missing directories", () => {
    expect(() => manager.create({ taskId: 99 })).toThrow(/no task 99/);
    const t = store.create({ title: "No project" });
    expect(() => manager.create({ taskId: t.id })).toThrow(/cwd is required/);
  });

  it("marks sessions exited and emits events", async () => {
    const events: string[] = [];
    manager.onEvent((e) => events.push(e.type));
    const info = manager.create({ cwd: work });
    manager.get(info.id).kill();
    await waitFor(() => manager.get(info.id).status === "exited", "exit");
    expect(events[0]).toBe("session.created");
    expect(events).toContain("session.updated");
    expect(() => manager.remove("nope")).toThrow();
    manager.remove(info.id);
    expect(manager.list()).toEqual([]);
  });
});
