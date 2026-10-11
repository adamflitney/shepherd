#!/usr/bin/env node
import { parseArgs } from "node:util";
import { TaskStore } from "./store.ts";
import { STATUSES, type Status, type Task } from "./task.ts";

const USAGE = `crook task <command>

  new <title> [--objective <text>] [--project <path>] [--branch <name>]
  list [--status <status>] [--json]
  show <id> [--json]
  link <id> [--session <id>]     (defaults to $CLAUDE_CODE_SESSION_ID)
  status <id> <${STATUSES.join("|")}>
  log <id> <text>
  plan <id> add <text> | check <n> | uncheck <n>
  find --session <id>            (prints the linked task id, exit 1 if none)
`;

function fail(msg: string): never {
  process.stderr.write(`crook: ${msg}\n`);
  process.exit(1);
}

function taskId(s: string | undefined): number {
  const n = Number(s);
  if (!s || !Number.isInteger(n) || n < 1) fail(`expected a task number, got "${s ?? ""}"`);
  return n;
}

function summary(t: Task): string {
  const p = t.progress;
  const progress = p.total ? ` (${p.done}/${p.total})` : "";
  return `${String(t.id).padStart(4)}  ${t.status.padEnd(7)} ${t.title}${progress}`;
}

function toJSON(t: Task) {
  return {
    id: t.id,
    title: t.title,
    objective: t.objective,
    projectPath: t.projectPath,
    status: t.status,
    sessions: t.sessions,
    branch: t.branch,
    pr: t.pr,
    progress: t.progress,
  };
}

function main(argv: string[]): void {
  const store = new TaskStore();
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      objective: { type: "string" },
      project: { type: "string" },
      branch: { type: "string" },
      session: { type: "string" },
      status: { type: "string" },
      json: { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
  });
  if (positionals[0] === "task") positionals.shift();
  const [cmd, ...rest] = positionals;
  if (!cmd || values.help) {
    process.stdout.write(USAGE);
    return;
  }

  switch (cmd) {
    case "new": {
      const title = rest.join(" ").trim();
      if (!title) fail("new needs a title");
      const t = store.create({ title, objective: values.objective, projectPath: values.project ?? process.cwd(), branch: values.branch });
      process.stdout.write(`${t.id}\n`);
      return;
    }
    case "list": {
      let tasks = store.list();
      if (values.status) tasks = tasks.filter((t) => t.status === values.status);
      process.stdout.write(values.json ? `${JSON.stringify(tasks.map(toJSON), null, 2)}\n` : tasks.map((t) => `${summary(t)}\n`).join(""));
      return;
    }
    case "show": {
      const t = store.get(taskId(rest[0])) ?? fail(`no task ${rest[0]}`);
      process.stdout.write(values.json ? `${JSON.stringify(toJSON(t), null, 2)}\n` : t.serialize());
      return;
    }
    case "link": {
      const id = taskId(rest[0]);
      const session = values.session ?? process.env.CLAUDE_CODE_SESSION_ID ?? fail("no session id: pass --session or run inside Claude Code");
      store.update(id, (t) => t.linkSession(session));
      return;
    }
    case "status": {
      const id = taskId(rest[0]);
      const status = rest[1] as Status;
      if (!(STATUSES as readonly string[]).includes(status)) fail(`status must be one of ${STATUSES.join(", ")}`);
      store.update(id, (t) => t.setStatus(status));
      return;
    }
    case "log": {
      const text = rest.slice(1).join(" ").trim();
      if (!text) fail("log needs text");
      store.update(taskId(rest[0]), (t) => t.appendLog(text));
      return;
    }
    case "plan": {
      const id = taskId(rest[0]);
      const [sub, ...args] = rest.slice(1);
      if (sub === "add" && args.length) store.update(id, (t) => t.addPlanItem(args.join(" ")));
      else if ((sub === "check" || sub === "uncheck") && args[0]) store.update(id, (t) => t.setPlanItem(taskId(args[0]), sub === "check"));
      else fail("plan <id> add <text> | check <n> | uncheck <n>");
      return;
    }
    case "find": {
      if (!values.session) fail("find needs --session");
      const t = store.findBySession(values.session);
      if (!t) process.exit(1);
      process.stdout.write(`${t.id}\n`);
      return;
    }
    default:
      fail(`unknown command "${cmd}"\n\n${USAGE}`);
  }
}

try {
  main(process.argv.slice(2));
} catch (e) {
  fail(e instanceof Error ? e.message : String(e));
}
