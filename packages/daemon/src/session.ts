import serializeAddon from "@xterm/addon-serialize";
import xtermHeadless, { type Terminal as XTerminal } from "@xterm/headless";
import pty from "node-pty";
import { attentionOf, reduceHookEvent, type Attention, type HookPayload, type HookState } from "./attention.ts";

// These are CommonJS packages: Node's ESM loader only exposes their default export, so the named
// exports have to be read off it (Vitest hides this, plain Node does not).
const { Terminal } = xtermHeadless;
const { SerializeAddon } = serializeAddon;

export type SessionStatus = "running" | "exited";

export interface SessionInfo {
  id: string;
  taskId?: number;
  cwd: string;
  command: string;
  title: string;
  status: SessionStatus;
  exitCode?: number;
  attention: Attention;
  cols: number;
  rows: number;
  createdAt: number;
  lastOutputAt: number;
}

export interface SessionOptions {
  id: string;
  taskId?: number;
  cwd: string;
  command: string;
  args: string[];
  env: Record<string, string>;
  title: string;
  /** Kept in front of titles the agent sets itself, e.g. "#4". */
  titlePrefix?: string;
  cols: number;
  rows: number;
}

/**
 * One agent process in a PTY, plus a headless terminal that tracks what is on screen so a client
 * can attach later (snapshot) or peek. Output is forwarded to listeners only after the headless
 * terminal has parsed it, so a snapshot taken in the same tick a listener is added is consistent
 * with the data that follows.
 */
export class Session {
  readonly id: string;
  readonly taskId: number | undefined;
  readonly cwd: string;
  readonly command: string;
  title: string;
  status: SessionStatus = "running";
  exitCode: number | undefined;
  readonly createdAt = Date.now();
  lastOutputAt = Date.now();
  /** Every id Claude Code has used for this conversation (it changes on /clear). */
  readonly claudeIds = new Set<string>();
  /** Clients currently attached; someone watching means a finish is not "unseen". */
  viewers = 0;

  private hook: HookState | undefined;
  private unseenFinish = false;
  private attention: Attention = { kind: "unknown", since: Date.now() };
  private proc: pty.IPty;
  private term: XTerminal;
  private serializer = new SerializeAddon();
  private dataListeners = new Set<(data: string) => void>();
  private changeListeners = new Set<() => void>();

  constructor(o: SessionOptions) {
    this.id = o.id;
    this.claudeIds.add(o.id);
    this.taskId = o.taskId;
    this.cwd = o.cwd;
    this.command = o.command;
    this.title = o.title;
    const prefix = o.titlePrefix;
    this.term = new Terminal({ cols: o.cols, rows: o.rows, scrollback: 5000, allowProposedApi: true });
    this.term.loadAddon(this.serializer);
    this.term.onTitleChange((t) => {
      if (t.trim()) {
        this.title = prefix ? `${prefix} ${t}` : t;
        this.emitChange();
      }
    });
    this.proc = pty.spawn(o.command, o.args, { name: "xterm-256color", cols: o.cols, rows: o.rows, cwd: o.cwd, env: o.env });
    this.proc.onData((data) => {
      this.lastOutputAt = Date.now();
      this.term.write(data, () => {
        for (const l of this.dataListeners) l(data);
      });
    });
    this.proc.onExit(({ exitCode }) => {
      // let the terminal finish parsing before announcing the exit
      this.term.write("", () => {
        this.status = "exited";
        this.exitCode = exitCode;
        if (this.viewers === 0) this.unseenFinish = true;
        this.recomputeAttention();
        this.emitChange();
      });
    });
  }

  get info(): SessionInfo {
    return {
      id: this.id,
      taskId: this.taskId,
      cwd: this.cwd,
      command: this.command,
      title: this.title,
      status: this.status,
      exitCode: this.exitCode,
      attention: this.attention,
      cols: this.term.cols,
      rows: this.term.rows,
      createdAt: this.createdAt,
      lastOutputAt: this.lastOutputAt,
    };
  }

  onData(cb: (data: string) => void): () => void {
    this.dataListeners.add(cb);
    return () => this.dataListeners.delete(cb);
  }

  onChange(cb: () => void): () => void {
    this.changeListeners.add(cb);
    return () => this.changeListeners.delete(cb);
  }

  private emitChange(): void {
    for (const l of this.changeListeners) l();
  }

  write(data: string): void {
    this.markSeen();
    if (this.status === "running") this.proc.write(data);
  }

  /** Feed one Claude Code hook payload for this session. */
  applyHook(payload: HookPayload): void {
    const result = reduceHookEvent(payload, this.hook);
    if (result.kind === "ignore") return;
    if (result.kind === "end") {
      this.hook = undefined;
      this.unseenFinish = false;
    } else {
      const was = this.hook?.state;
      this.hook = result.state;
      const finished = result.state.state === "idle" || result.state.state === "stalled";
      if (was === "working" && finished && this.viewers === 0) this.unseenFinish = true;
      if (result.state.state === "working") this.unseenFinish = false;
    }
    this.recomputeAttention();
  }

  /** Someone looked at, or typed into, the session. */
  markSeen(): void {
    if (!this.unseenFinish) return;
    this.unseenFinish = false;
    this.recomputeAttention();
  }

  viewerAttached(): void {
    this.viewers++;
    this.markSeen();
  }

  viewerDetached(): void {
    this.viewers = Math.max(0, this.viewers - 1);
  }

  private recomputeAttention(): void {
    const next = attentionOf({ exited: this.status === "exited", exitCode: this.exitCode, hook: this.hook, unseenFinish: this.unseenFinish });
    const { since: _since, ...prev } = this.attention;
    if (JSON.stringify(next) === JSON.stringify(prev)) return;
    this.attention = { ...next, since: Date.now() };
    this.emitChange();
  }

  resize(cols: number, rows: number): void {
    if (this.status !== "running") return;
    this.proc.resize(cols, rows);
    this.term.resize(cols, rows);
    this.emitChange();
  }

  /** Escape sequences that redraw the current screen (and scrollback) on a fresh terminal. */
  snapshot(): string {
    return this.serializer.serialize();
  }

  /** Plain text of the visible screen, trailing blank lines removed. */
  peek(): string {
    const buf = this.term.buffer.active;
    const lines: string[] = [];
    for (let y = 0; y < this.term.rows; y++) lines.push(buf.getLine(buf.baseY + y)?.translateToString(true) ?? "");
    while (lines.length && lines.at(-1)!.trim() === "") lines.pop();
    return lines.join("\n");
  }

  kill(): void {
    if (this.status !== "running") return;
    this.proc.kill();
    const t = setTimeout(() => {
      if (this.status === "running") this.proc.kill("SIGKILL");
    }, 3000);
    t.unref();
  }
}
