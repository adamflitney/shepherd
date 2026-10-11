import { randomUUID } from "node:crypto";
import { basename } from "node:path";
import { TaskStore } from "@shepherd/tasks";
import { claudeAgent, type AgentSpec } from "./agent.ts";
import type { HookPayload } from "./attention.ts";
import { Session, type SessionInfo } from "./session.ts";

export interface CreateRequest {
  /** Directory to run in. Defaults to the task's project path. */
  cwd?: string;
  /** Start (or resume) work on this task. */
  taskId?: number;
  prompt?: string;
  cols?: number;
  rows?: number;
}

export type ManagerEvent =
  | { type: "session.created"; session: SessionInfo }
  | { type: "session.updated"; session: SessionInfo }
  | { type: "session.removed"; id: string };

export interface ManagerOptions {
  store?: TaskStore;
  agent?: AgentSpec;
  env?: NodeJS.ProcessEnv;
}

/**
 * Variables Claude Code sets for the process it is running in. If the daemon is started from
 * inside a Claude Code session they would leak into every agent it launches, and e.g.
 * CLAUDE_CODE_CHILD_SESSION turns transcript saving off, which breaks resuming.
 */
const SESSION_SCOPED_ENV = [
  "CLAUDECODE",
  "CLAUDE_PID",
  "CLAUDE_EFFORT",
  "CLAUDE_CODE_CHILD_SESSION",
  "CLAUDE_CODE_ENTRYPOINT",
  "CLAUDE_CODE_EXECPATH",
  "CLAUDE_CODE_MESSAGING_SOCKET",
  "CLAUDE_CODE_MESSAGING_TOKEN",
  "CLAUDE_CODE_SESSION_ATTENDED",
  "CLAUDE_CODE_SESSION_ID",
];

const DEFAULT_TASK_PROMPT = "Start on the task described in your session context.";

export class SessionManager {
  private sessions = new Map<string, Session>();
  private listeners = new Set<(e: ManagerEvent) => void>();
  readonly store: TaskStore;
  private agent: AgentSpec;
  private env: NodeJS.ProcessEnv;

  constructor(o: ManagerOptions = {}) {
    this.store = o.store ?? new TaskStore();
    this.agent = o.agent ?? claudeAgent;
    this.env = o.env ?? process.env;
  }

  onEvent(cb: (e: ManagerEvent) => void): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  private emit(e: ManagerEvent): void {
    for (const l of this.listeners) l(e);
  }

  list(): SessionInfo[] {
    return [...this.sessions.values()].map((s) => s.info).sort((a, b) => a.createdAt - b.createdAt);
  }

  get(id: string): Session {
    const s = this.sessions.get(id);
    if (!s) throw new Error(`no session ${id}`);
    return s;
  }

  create(req: CreateRequest): SessionInfo {
    const task = req.taskId !== undefined ? this.store.get(req.taskId) : undefined;
    if (req.taskId !== undefined && !task) throw new Error(`no task ${req.taskId}`);
    const cwd = req.cwd ?? task?.projectPath;
    if (!cwd) throw new Error("cwd is required (the task has no project_path)");

    // A task that already has a conversation on disk is resumed; otherwise start a new one
    // under an id we choose, so the task link exists before the agent has printed anything.
    const resumeId = task?.sessions
      .slice()
      .reverse()
      .find((id) => !this.isLive(id) && this.agent.canResume(cwd, id));
    const sessionId = resumeId ?? randomUUID();
    const prompt = req.prompt ?? (task && !resumeId ? DEFAULT_TASK_PROMPT : undefined);

    const env: Record<string, string> = {};
    for (const [k, v] of Object.entries(this.env)) if (v !== undefined) env[k] = v;
    for (const k of SESSION_SCOPED_ENV) delete env[k];
    env.TERM = "xterm-256color";
    env.COLORTERM = "truecolor";
    env.SHEPHERD_SESSION_ID = sessionId;
    if (task) env.SHEPHERD_TASK_ID = String(task.id);
    else delete env.SHEPHERD_TASK_ID;

    if (task && !resumeId) this.store.update(task.id, (t) => t.linkSession(sessionId));

    const session = new Session({
      id: sessionId,
      taskId: task?.id,
      cwd,
      command: this.agent.command,
      args: this.agent.args({ sessionId, resume: resumeId !== undefined, prompt }),
      env,
      title: task ? `#${task.id} ${task.title}` : basename(cwd),
      titlePrefix: task ? `#${task.id}` : undefined,
      cols: req.cols ?? 120,
      rows: req.rows ?? 32,
    });
    this.sessions.set(sessionId, session);
    session.onChange(() => this.emit({ type: "session.updated", session: session.info }));
    this.emit({ type: "session.created", session: session.info });
    return session.info;
  }

  /**
   * Routes a hook payload to the session it belongs to. The payload's session id is the
   * conversation's current id; after /clear that is a new id, so `shepherdSessionId` (from the
   * SHEPHERD_SESSION_ID the agent was started with) identifies the session and teaches us the alias.
   * Returns false for sessions we don't own (a claude running elsewhere).
   */
  handleHook(payload: HookPayload, shepherdSessionId?: string): boolean {
    const id = payload.session_id;
    let session = id ? [...this.sessions.values()].find((s) => s.claudeIds.has(id)) : undefined;
    if (!session && shepherdSessionId) {
      session = this.sessions.get(shepherdSessionId);
      if (session && id) session.claudeIds.add(id);
    }
    if (!session) return false;
    session.applyHook(payload);
    return true;
  }

  private isLive(id: string): boolean {
    return this.sessions.get(id)?.status === "running";
  }

  /** Forgets an exited session (running ones must be killed first). */
  remove(id: string): void {
    const s = this.get(id);
    if (s.status === "running") throw new Error(`session ${id} is still running`);
    this.sessions.delete(id);
    this.emit({ type: "session.removed", id });
  }

  shutdown(): void {
    for (const s of this.sessions.values()) s.kill();
  }
}
