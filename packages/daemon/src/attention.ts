// Attention state for a session, derived from Claude Code hook events. This is a port of
// Sources/Shepherd/HookScripts/shepherd_write_state.py plus the projection in
// Sources/ShepherdHerdr/HookState.swift, but with the daemon as the only source: there is no
// herdr screen detection underneath, so hooks decide working/blocked/idle too.

export type HookStateName = "working" | "idle" | "stalled" | "needs-permission" | "asked-a-question";

export interface Todos {
  done: number;
  total: number;
  activeForm?: string;
}

export interface HookDetail {
  toolName?: string;
  summary?: string;
  question?: string;
  options?: string[];
  multiSelect?: boolean;
  todos?: Todos;
}

export interface HookState {
  state: HookStateName;
  detail: HookDetail;
}

export interface HookPayload {
  hook_event_name?: string;
  session_id?: string;
  notification_type?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  agent_id?: string;
  [key: string]: unknown;
}

/** Tools that block on a human decision without being a "permission" in the usual sense. */
const QUESTION_TOOLS = new Set(["AskUserQuestion", "ExitPlanMode"]);

export type HookResult =
  | { kind: "state"; state: HookState }
  | { kind: "end" } // SessionEnd: forget everything we knew
  | { kind: "ignore" };

const IGNORE: HookResult = { kind: "ignore" };

export function reduceHookEvent(payload: HookPayload, existing: HookState | undefined): HookResult {
  if (payload.agent_id || payload.hook_event_name === "SubagentStop") return IGNORE; // subagents don't speak for the session
  const tool = payload.tool_name;
  const input = payload.tool_input ?? {};
  const state = (s: HookStateName, detail: HookDetail = {}): HookResult => ({ kind: "state", state: { state: s, detail } });

  switch (payload.hook_event_name) {
    case "SessionEnd":
      return { kind: "end" };

    case "PermissionRequest":
      if (tool && QUESTION_TOOLS.has(tool)) {
        return state("asked-a-question", { toolName: tool, ...(tool === "AskUserQuestion" ? askUserQuestion(input) : {}) });
      }
      return state("needs-permission", { toolName: tool, summary: summarizePermission(tool, input) });

    case "Notification":
      if (payload.notification_type === "idle_prompt") return state("idle");
      if (payload.notification_type === "agent_needs_input") return state("asked-a-question");
      // permission_prompt is a delayed "still waiting" echo of a PermissionRequest we already
      // recorded with better detail.
      return IGNORE;

    case "UserPromptSubmit":
      return state("working");

    case "Stop": {
      // Stop is the only reliable clearer of a stale blocked state, and the only place "stalled"
      // (stopped with unfinished todos) can be derived.
      const todos = existing?.detail.todos;
      if (todos && todos.total > 0 && todos.done < todos.total) return state("stalled", { todos });
      return state("idle");
    }

    case "PostToolUse": {
      const current = existing?.state ?? "working";
      if (tool === "TodoWrite") {
        // A todo update doesn't change the lifecycle state; it attaches progress for a later Stop.
        return state(current, { ...existing?.detail, todos: summarizeTodos(input.todos) });
      }
      // A tool finishing means whatever we were blocked on has been answered. There is no
      // dedicated "resolved" event, so this is how a permission prompt stops counting as blocking.
      if (current === "needs-permission" || current === "asked-a-question") {
        return state("working", existing?.detail.todos ? { todos: existing.detail.todos } : {});
      }
      return IGNORE;
    }

    default:
      return IGNORE;
  }
}

function summarizeTodos(raw: unknown): Todos {
  const todos = Array.isArray(raw) ? (raw as Record<string, unknown>[]) : [];
  const active = todos.find((t) => t.status === "in_progress")?.activeForm;
  return {
    done: todos.filter((t) => t.status === "completed").length,
    total: todos.length,
    ...(typeof active === "string" ? { activeForm: active } : {}),
  };
}

/** AskUserQuestion's input carries the exact question and labelled options Claude Code renders. */
function askUserQuestion(input: Record<string, unknown>): HookDetail {
  const questions = Array.isArray(input.questions) ? (input.questions as Record<string, unknown>[]) : [];
  const first = questions[0];
  if (!first) return {};
  const options = (Array.isArray(first.options) ? (first.options as Record<string, unknown>[]) : [])
    .map((o) => o.label)
    .filter((l): l is string => typeof l === "string" && l !== "");
  return {
    ...(typeof first.question === "string" && first.question ? { question: first.question } : {}),
    ...(options.length ? { options } : {}),
    ...(first.multiSelect ? { multiSelect: true } : {}),
  };
}

/** One line saying what is being approved: "Bash: npm test", "Edit: src/a.ts". */
function summarizePermission(tool: string | undefined, input: Record<string, unknown>): string {
  let detail: unknown;
  if (tool === "Bash") detail = input.description || input.command;
  else if (tool === "Write" || tool === "Edit" || tool === "NotebookEdit") detail = input.file_path;
  else if (tool === "WebFetch") detail = input.url;
  else if (tool === "WebSearch") detail = input.query;
  return typeof detail === "string" && detail ? `${tool}: ${detail}` : (tool ?? "tool");
}

// ---------------------------------------------------------------------------------------------

export type AttentionKind = "blocked" | "done" | "working" | "idle" | "unknown";
export type Blocker = "needsAnswer" | "needsPermission" | "failed";

export interface Attention {
  kind: AttentionKind;
  blocker?: Blocker;
  summary?: string;
  options?: string[];
  optionsAllowMultiple?: boolean;
  progress?: { completed: number; total: number; currentItem?: string };
  /** Epoch ms when the session entered this state. */
  since: number;
}

export interface AttentionInput {
  exited: boolean;
  exitCode?: number;
  hook?: HookState;
  /** The agent finished while nobody was looking. */
  unseenFinish: boolean;
}

/** Attention without `since`; the session stamps that when the value changes. */
export function attentionOf(i: AttentionInput): Omit<Attention, "since"> {
  const finished = (): Omit<Attention, "since"> => ({ kind: i.unseenFinish ? "done" : "idle" });
  if (i.exited) {
    if (i.exitCode !== undefined && i.exitCode !== 0) return { kind: "blocked", blocker: "failed", summary: `exited with code ${i.exitCode}` };
    return finished();
  }
  const h = i.hook;
  if (!h) return { kind: "unknown" };
  const t = h.detail.todos;
  const progress = t && t.total > 0 ? { completed: t.done, total: t.total, ...(t.activeForm ? { currentItem: t.activeForm } : {}) } : undefined;
  switch (h.state) {
    case "needs-permission":
      return { kind: "blocked", blocker: "needsPermission", summary: h.detail.summary ?? h.detail.toolName };
    case "asked-a-question":
      return {
        kind: "blocked",
        blocker: "needsAnswer",
        summary: h.detail.question ?? h.detail.toolName,
        ...(h.detail.options ? { options: h.detail.options, optionsAllowMultiple: h.detail.multiSelect ?? false } : {}),
      };
    case "working":
      return { kind: "working", ...(progress ? { progress } : {}) };
    case "stalled":
      return { ...finished(), ...(progress ? { progress } : {}) };
    case "idle":
      return finished();
  }
}
