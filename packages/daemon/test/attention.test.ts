import { describe, expect, it } from "vitest";
import { attentionOf, reduceHookEvent, type HookPayload, type HookState } from "../src/attention.ts";

const reduce = (p: HookPayload, existing?: HookState) => reduceHookEvent(p, existing);
const stateOf = (p: HookPayload, existing?: HookState) => {
  const r = reduce(p, existing);
  if (r.kind !== "state") throw new Error(`expected a state, got ${r.kind}`);
  return r.state;
};

describe("reduceHookEvent", () => {
  it("a prompt means working, Stop means idle", () => {
    expect(stateOf({ hook_event_name: "UserPromptSubmit" }).state).toBe("working");
    expect(stateOf({ hook_event_name: "Stop" }).state).toBe("idle");
  });

  it("a permission request records what is being approved", () => {
    const s = stateOf({ hook_event_name: "PermissionRequest", tool_name: "Bash", tool_input: { command: "rm -rf build", description: "Clean build dir" } });
    expect(s).toEqual({ state: "needs-permission", detail: { toolName: "Bash", summary: "Bash: Clean build dir" } });
    expect(stateOf({ hook_event_name: "PermissionRequest", tool_name: "Edit", tool_input: { file_path: "src/a.ts" } }).detail.summary).toBe("Edit: src/a.ts");
    expect(stateOf({ hook_event_name: "PermissionRequest", tool_name: "Mystery" }).detail.summary).toBe("Mystery");
  });

  it("AskUserQuestion and ExitPlanMode are questions, with the real labelled options", () => {
    const q = stateOf({
      hook_event_name: "PermissionRequest",
      tool_name: "AskUserQuestion",
      tool_input: { questions: [{ question: "Which db?", multiSelect: true, options: [{ label: "pg" }, { label: "sqlite" }, {}] }] },
    });
    expect(q).toEqual({ state: "asked-a-question", detail: { toolName: "AskUserQuestion", question: "Which db?", options: ["pg", "sqlite"], multiSelect: true } });
    expect(stateOf({ hook_event_name: "PermissionRequest", tool_name: "ExitPlanMode" }).state).toBe("asked-a-question");
  });

  it("notifications: idle_prompt is idle, the permission_prompt echo is ignored", () => {
    expect(stateOf({ hook_event_name: "Notification", notification_type: "idle_prompt" }).state).toBe("idle");
    expect(stateOf({ hook_event_name: "Notification", notification_type: "agent_needs_input" }).state).toBe("asked-a-question");
    expect(reduce({ hook_event_name: "Notification", notification_type: "permission_prompt" }).kind).toBe("ignore");
  });

  it("stopping with unfinished todos is stalled; with all done it is idle", () => {
    const todos = { done: 1, total: 3, activeForm: "Writing" };
    expect(stateOf({ hook_event_name: "Stop" }, { state: "working", detail: { todos } })).toEqual({ state: "stalled", detail: { todos } });
    expect(stateOf({ hook_event_name: "Stop" }, { state: "working", detail: { todos: { done: 3, total: 3 } } }).state).toBe("idle");
  });

  it("TodoWrite attaches progress without changing the lifecycle state", () => {
    const s = stateOf(
      { hook_event_name: "PostToolUse", tool_name: "TodoWrite", tool_input: { todos: [{ status: "completed" }, { status: "in_progress", activeForm: "Testing" }, { status: "pending" }] } },
      { state: "working", detail: {} },
    );
    expect(s).toEqual({ state: "working", detail: { todos: { done: 1, total: 3, activeForm: "Testing" } } });
  });

  it("a finished tool call clears a blocked state, and is otherwise ignored", () => {
    const blocked: HookState = { state: "needs-permission", detail: { summary: "Bash: x", todos: { done: 0, total: 2 } } };
    expect(stateOf({ hook_event_name: "PostToolUse", tool_name: "Bash" }, blocked)).toEqual({ state: "working", detail: { todos: { done: 0, total: 2 } } });
    expect(reduce({ hook_event_name: "PostToolUse", tool_name: "Bash" }, { state: "working", detail: {} }).kind).toBe("ignore");
    expect(reduce({ hook_event_name: "PostToolUse", tool_name: "Bash" }, { state: "idle", detail: {} }).kind).toBe("ignore");
  });

  it("SessionEnd forgets the state; subagent and unknown events are ignored", () => {
    expect(reduce({ hook_event_name: "SessionEnd" }).kind).toBe("end");
    expect(reduce({ hook_event_name: "Stop", agent_id: "sub1" }).kind).toBe("ignore");
    expect(reduce({ hook_event_name: "SubagentStop" }).kind).toBe("ignore");
    expect(reduce({ hook_event_name: "PreCompact" }).kind).toBe("ignore");
  });
});

describe("attentionOf", () => {
  const base = { exited: false, unseenFinish: false };
  it("is unknown until a hook has been seen", () => {
    expect(attentionOf(base).kind).toBe("unknown");
  });
  it("maps blocked states to blockers with a summary", () => {
    expect(attentionOf({ ...base, hook: { state: "needs-permission", detail: { summary: "Bash: ls" } } })).toEqual({ kind: "blocked", blocker: "needsPermission", summary: "Bash: ls" });
    const q = attentionOf({ ...base, hook: { state: "asked-a-question", detail: { question: "Which?", options: ["a", "b"] } } });
    expect(q).toMatchObject({ kind: "blocked", blocker: "needsAnswer", summary: "Which?", options: ["a", "b"], optionsAllowMultiple: false });
  });
  it("working carries todo progress", () => {
    expect(attentionOf({ ...base, hook: { state: "working", detail: { todos: { done: 1, total: 4, activeForm: "Go" } } } })).toEqual({
      kind: "working",
      progress: { completed: 1, total: 4, currentItem: "Go" },
    });
  });
  it("finishing unseen is done, finishing seen is idle, a stalled stop keeps its progress", () => {
    const idle: HookState = { state: "idle", detail: {} };
    expect(attentionOf({ ...base, hook: idle, unseenFinish: true }).kind).toBe("done");
    expect(attentionOf({ ...base, hook: idle }).kind).toBe("idle");
    expect(attentionOf({ ...base, hook: { state: "stalled", detail: { todos: { done: 1, total: 2 } } } })).toEqual({ kind: "idle", progress: { completed: 1, total: 2 } });
  });
  it("exits: clean is done/idle, a crash is blocked as failed", () => {
    expect(attentionOf({ exited: true, exitCode: 0, unseenFinish: true }).kind).toBe("done");
    expect(attentionOf({ exited: true, exitCode: 0, unseenFinish: false }).kind).toBe("idle");
    expect(attentionOf({ exited: true, exitCode: 130, unseenFinish: false })).toEqual({ kind: "blocked", blocker: "failed", summary: "exited with code 130" });
  });
});
