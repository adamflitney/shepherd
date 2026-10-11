import { Frontmatter } from "./frontmatter.ts";

export const STATUSES = ["inbox", "ready", "active", "review", "done"] as const;
export type Status = (typeof STATUSES)[number];

export function formatStamp(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

export class Task {
  private doc: Frontmatter;

  private constructor(doc: Frontmatter) {
    this.doc = doc;
  }

  static parse(text: string): Task {
    return new Task(Frontmatter.parse(text));
  }

  static create(id: number, input: { title: string; objective?: string; projectPath?: string; branch?: string }, now: Date): Task {
    const doc = Frontmatter.parse(`---\nid: ${id}\n---\n## Plan\n\n## Log\n`);
    const stamp = formatStamp(now);
    doc.set("title", input.title);
    doc.set("objective", input.objective);
    doc.set("project_path", input.projectPath);
    doc.set("status", "inbox");
    doc.set("sessions", []);
    doc.set("branch", input.branch);
    doc.set("created", stamp);
    doc.set("updated", stamp);
    return new Task(doc);
  }

  serialize(): string {
    return this.doc.serialize();
  }

  get body(): string {
    return this.doc.body;
  }

  private str(key: string): string | undefined {
    const v = this.doc.get(key);
    return typeof v === "string" ? v : v === undefined ? undefined : String(v);
  }

  get id(): number {
    const v = this.doc.get("id");
    if (typeof v !== "number") throw new Error("task has no numeric id");
    return v;
  }
  get title(): string {
    return this.str("title") ?? "";
  }
  get objective(): string | undefined {
    return this.str("objective");
  }
  get projectPath(): string | undefined {
    return this.str("project_path");
  }
  get branch(): string | undefined {
    return this.str("branch");
  }
  get pr(): string | undefined {
    return this.str("pr");
  }
  get status(): Status {
    const v = this.str("status");
    return (STATUSES as readonly string[]).includes(v ?? "") ? (v as Status) : "inbox";
  }
  get sessions(): string[] {
    const v = this.doc.get("sessions");
    return Array.isArray(v) ? v.map(String) : [];
  }

  setStatus(status: Status, now?: Date): void {
    if (!(STATUSES as readonly string[]).includes(status)) throw new Error(`invalid status "${status}" (expected ${STATUSES.join(" | ")})`);
    this.doc.set("status", status);
    this.touch(now);
  }

  linkSession(sessionId: string, now?: Date): void {
    if (!this.sessions.includes(sessionId)) {
      this.doc.set("sessions", [...this.sessions, sessionId]);
      this.touch(now);
    }
  }

  unlinkSession(sessionId: string, now?: Date): void {
    this.doc.set("sessions", this.sessions.filter((s) => s !== sessionId));
    this.touch(now);
  }

  touch(now: Date = new Date()): void {
    this.doc.set("updated", formatStamp(now));
  }

  /** Appends "- YYYY-MM-DD HH:MM: text" at the end of the ## Log section (creating it if needed). */
  appendLog(text: string, now: Date = new Date()): void {
    const stamp = formatStamp(now);
    const entry = `- ${stamp.slice(0, 10)} ${stamp.slice(11, 16)}: ${text}`;
    this.appendToSection("Log", entry);
    this.touch(now);
  }

  addPlanItem(text: string, now?: Date): void {
    this.appendToSection("Plan", `- [ ] ${text}`);
    this.touch(now);
  }

  /** Sets plan item n (1-based) done or not done. */
  setPlanItem(n: number, done: boolean, now?: Date): void {
    const lines = this.doc.body.split("\n");
    const range = findSection(lines, "Plan");
    let seen = 0;
    if (range) {
      for (let i = range.start + 1; i < range.end; i++) {
        if (/^- \[[ xX]\] /.test(lines[i]!) && ++seen === n) {
          lines[i] = lines[i]!.replace(/^- \[[ xX]\]/, done ? "- [x]" : "- [ ]");
          this.doc.body = lines.join("\n");
          this.touch(now);
          return;
        }
      }
    }
    throw new Error(`no plan item ${n}`);
  }

  get progress(): { done: number; total: number } {
    const lines = this.doc.body.split("\n");
    const range = findSection(lines, "Plan");
    let done = 0;
    let total = 0;
    if (range) {
      for (let i = range.start + 1; i < range.end; i++) {
        const m = /^- \[([ xX])\] /.exec(lines[i]!);
        if (m) {
          total++;
          if (m[1] !== " ") done++;
        }
      }
    }
    return { done, total };
  }

  private appendToSection(name: string, line: string): void {
    const lines = this.doc.body.split("\n");
    const range = findSection(lines, name);
    if (!range) {
      let body = this.doc.body;
      if (body !== "" && !body.endsWith("\n")) body += "\n";
      if (body !== "") body += "\n";
      this.doc.body = `${body}## ${name}\n${line}\n`;
      return;
    }
    let at = range.end;
    while (at > range.start + 1 && lines[at - 1]!.trim() === "") at--; // before trailing blank lines
    lines.splice(at, 0, line);
    this.doc.body = lines.join("\n");
  }
}

/** Line range of "## name" through the line before the next "## " heading (or end). */
function findSection(lines: string[], name: string): { start: number; end: number } | undefined {
  const start = lines.findIndex((l) => l.trim() === `## ${name}`);
  if (start === -1) return undefined;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^## /.test(lines[i]!)) {
      end = i;
      break;
    }
  }
  return { start, end };
}
