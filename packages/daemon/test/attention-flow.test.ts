import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TaskStore } from "@shepherd/tasks";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DaemonClient } from "../src/client.ts";
import { SessionManager } from "../src/manager.ts";
import { DaemonServer } from "../src/server.ts";
import type { SessionInfo } from "../src/session.ts";
import { fakeAgent, waitFor } from "./helpers.ts";

let manager: SessionManager;
let work: string;
const kind = (id: string) => manager.get(id).info.attention.kind;

beforeEach(() => {
  work = mkdtempSync(join(tmpdir(), "shep-work-"));
  manager = new SessionManager({ store: new TaskStore(mkdtempSync(join(tmpdir(), "shep-tasks-"))), agent: fakeAgent(), env: { PATH: process.env.PATH } });
});
afterEach(() => manager.shutdown());

describe("attention flow", () => {
  it("follows a turn: unknown, working, blocked on permission, working again, done when unseen", () => {
    const { id } = manager.create({ cwd: work });
    expect(kind(id)).toBe("unknown");
    manager.handleHook({ hook_event_name: "UserPromptSubmit", session_id: id });
    expect(kind(id)).toBe("working");
    manager.handleHook({ hook_event_name: "PermissionRequest", session_id: id, tool_name: "Bash", tool_input: { command: "npm test" } });
    expect(manager.get(id).info.attention).toMatchObject({ kind: "blocked", blocker: "needsPermission", summary: "Bash: npm test" });
    manager.handleHook({ hook_event_name: "PostToolUse", session_id: id, tool_name: "Bash" });
    expect(kind(id)).toBe("working");
    manager.handleHook({ hook_event_name: "Stop", session_id: id });
    expect(kind(id)).toBe("done"); // nobody was watching
  });

  it("a finish is idle, not done, when someone is attached; and attaching clears done", () => {
    const a = manager.create({ cwd: work }).id;
    const b = manager.create({ cwd: work }).id;
    manager.get(a).viewerAttached();
    for (const id of [a, b]) {
      manager.handleHook({ hook_event_name: "UserPromptSubmit", session_id: id });
      manager.handleHook({ hook_event_name: "Stop", session_id: id });
    }
    expect(kind(a)).toBe("idle");
    expect(kind(b)).toBe("done");
    manager.get(b).viewerAttached();
    expect(kind(b)).toBe("idle");
  });

  it("typing into a done session marks it seen", () => {
    const { id } = manager.create({ cwd: work });
    manager.handleHook({ hook_event_name: "UserPromptSubmit", session_id: id });
    manager.handleHook({ hook_event_name: "Stop", session_id: id });
    expect(kind(id)).toBe("done");
    manager.get(id).write("x");
    expect(kind(id)).toBe("idle");
  });

  it("emits updates only when attention actually changes, with a fresh since", async () => {
    const { id } = manager.create({ cwd: work });
    const updates: string[] = [];
    manager.onEvent((e) => e.type === "session.updated" && updates.push(e.session.attention.kind));
    manager.handleHook({ hook_event_name: "UserPromptSubmit", session_id: id });
    const since = manager.get(id).info.attention.since;
    manager.handleHook({ hook_event_name: "UserPromptSubmit", session_id: id }); // no change
    manager.handleHook({ hook_event_name: "PostToolUse", session_id: id, tool_name: "Bash" }); // ignored
    expect(updates).toEqual(["working"]);
    await new Promise((r) => setTimeout(r, 5));
    manager.handleHook({ hook_event_name: "Stop", session_id: id });
    expect(manager.get(id).info.attention.since).toBeGreaterThan(since);
  });

  it("keeps routing after /clear changes Claude's session id, via SHEPHERD_SESSION_ID", () => {
    const { id } = manager.create({ cwd: work });
    expect(manager.handleHook({ hook_event_name: "UserPromptSubmit", session_id: "new-id-after-clear" }, id)).toBe(true);
    expect(kind(id)).toBe("working");
    // now known by the new id alone
    expect(manager.handleHook({ hook_event_name: "Stop", session_id: "new-id-after-clear" })).toBe(true);
    expect(manager.handleHook({ hook_event_name: "Stop", session_id: "someone-elses-claude" })).toBe(false);
  });

  it("an exit is done when unseen, and a non-zero exit is blocked as failed", async () => {
    const { id } = manager.create({ cwd: work });
    manager.get(id).write("exit 3\r");
    await waitFor(() => manager.get(id).status === "exited", "exit");
    expect(manager.get(id).info.attention).toMatchObject({ kind: "blocked", blocker: "failed", summary: "exited with code 3" });
  });
});

describe("hook.event over the socket", () => {
  it("lets a separate process report hook events, counting attached clients as viewers", async () => {
    const dir = mkdtempSync(join(tmpdir(), "shep-"));
    const server = new DaemonServer(manager, join(dir, "s.sock"));
    await server.listen();
    const c = await DaemonClient.connect(join(dir, "s.sock"));
    try {
      const info = await c.request<SessionInfo>("session.create", { cwd: work });
      await c.request("session.attach", { id: info.id });
      expect(manager.get(info.id).viewers).toBe(1);
      await c.request("hook.event", { payload: { hook_event_name: "UserPromptSubmit", session_id: info.id } });
      await c.request("hook.event", { payload: { hook_event_name: "Stop", session_id: info.id } });
      expect(kind(info.id)).toBe("idle"); // attached, so not "done"
      expect(await c.request("hook.event", { payload: { hook_event_name: "Stop", session_id: "unknown" } })).toEqual({ handled: false });
      c.close();
      await waitFor(() => manager.get(info.id).viewers === 0, "viewer cleanup on disconnect");
    } finally {
      c.close();
      await server.close();
    }
  });
});
