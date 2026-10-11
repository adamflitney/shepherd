import { mkdirSync, readFileSync, readdirSync, renameSync, rmdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { formatStamp, Task } from "./task.ts";

export function defaultTasksDir(): string {
  const home = process.env.SHEPHERD_HOME ?? join(homedir(), ".shepherd");
  return join(home, "tasks");
}

const FILE = /^(\d+)-.*\.md$/;

export interface NewTask {
  title: string;
  objective?: string;
  projectPath?: string;
  branch?: string;
}

export class TaskStore {
  readonly dir: string;

  constructor(dir: string = defaultTasksDir()) {
    this.dir = dir;
  }

  private files(): { id: number; path: string }[] {
    try {
      return readdirSync(this.dir)
        .flatMap((name) => {
          const m = FILE.exec(name);
          return m ? [{ id: Number(m[1]), path: join(this.dir, name) }] : [];
        })
        .sort((a, b) => a.id - b.id);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw e;
    }
  }

  list(): Task[] {
    return this.files().map((f) => Task.parse(readFileSync(f.path, "utf8")));
  }

  get(id: number): Task | undefined {
    const f = this.files().find((x) => x.id === id);
    return f ? Task.parse(readFileSync(f.path, "utf8")) : undefined;
  }

  findBySession(sessionId: string): Task | undefined {
    return this.list().find((t) => t.sessions.includes(sessionId));
  }

  create(input: NewTask, now: Date = new Date()): Task {
    mkdirSync(this.dir, { recursive: true });
    return this.withLock(() => {
      const id = (this.files().at(-1)?.id ?? 0) + 1;
      const task = Task.create(id, input, now);
      atomicWrite(join(this.dir, `${String(id).padStart(4, "0")}-${slug(input.title)}.md`), task.serialize());
      return task;
    });
  }

  /** Re-reads the file just before writing and applies `fn`, so only intended fields change. */
  update(id: number, fn: (t: Task) => void, now: Date = new Date()): Task {
    const f = this.files().find((x) => x.id === id);
    if (!f) throw new Error(`no task ${id}`);
    const task = Task.parse(readFileSync(f.path, "utf8"));
    fn(task);
    task.touch(now);
    atomicWrite(f.path, task.serialize());
    return task;
  }

  private withLock<T>(fn: () => T): T {
    const lock = join(this.dir, ".lock");
    for (let i = 0; ; i++) {
      try {
        mkdirSync(lock);
        break;
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "EEXIST" || i > 200) throw e;
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
      }
    }
    try {
      return fn();
    } finally {
      rmdirSync(lock);
    }
  }
}

function atomicWrite(path: string, text: string): void {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, text);
  renameSync(tmp, path);
}

export function slug(title: string): string {
  const s = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40)
    .replace(/-+$/, "");
  return s || "task";
}
