#!/usr/bin/env node
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { DaemonClient } from "./client.ts";
import { installedEvents, installHooks, stripHooks } from "./hooks.ts";
import { runDaemon } from "./daemon.ts";
import { socketPath } from "./paths.ts";
import type { SessionInfo } from "./session.ts";

const USAGE = `shepctl <command>

  daemon                         run the daemon in the foreground
  list                           sessions
  new [--task <n>] [--cwd <dir>] [prompt...]
  attach <id>                    interactive terminal (Ctrl-] to detach)
  peek <id>                      what is on screen right now
  send <id> <text...>            type text and press Enter
  key <id> <key>...              enter esc tab up down left right space ctrl-c
  kill <id>
  hooks install|uninstall|status [--file <settings.json>]
                                 register shepherd's Claude Code hooks (default ~/.claude/settings.json)
`;

const KEYS: Record<string, string> = {
  enter: "\r",
  esc: "\x1b",
  tab: "\t",
  up: "\x1b[A",
  down: "\x1b[B",
  right: "\x1b[C",
  left: "\x1b[D",
  space: " ",
  "ctrl-c": "\x03",
};

function fail(msg: string): never {
  process.stderr.write(`shepctl: ${msg}\n`);
  process.exit(1);
}

async function connect(): Promise<DaemonClient> {
  try {
    return await DaemonClient.connect(socketPath());
  } catch {
    return fail(`cannot reach the daemon at ${socketPath()} (start it with: shepctl daemon)`);
  }
}

/** Resolve a unique id prefix against the session list. */
async function resolveId(c: DaemonClient, prefix: string | undefined): Promise<string> {
  if (!prefix) fail("session id required");
  const { sessions } = await c.request<{ sessions: SessionInfo[] }>("session.list");
  const hits = sessions.filter((s) => s.id.startsWith(prefix));
  if (hits.length !== 1) fail(hits.length ? `"${prefix}" is ambiguous` : `no session "${prefix}"`);
  return hits[0]!.id;
}

async function attach(c: DaemonClient, id: string): Promise<void> {
  const out = process.stdout;
  const size = () => ({ cols: out.columns ?? 120, rows: out.rows ?? 32 });
  await c.request("session.resize", { id, ...size() });
  const { snapshot } = await c.request<{ snapshot: string }>("session.attach", { id });
  out.write(`\x1b[2J\x1b[H${snapshot}`);
  c.onEvent((e) => {
    if (e.event === "session.data" && e.id === id) out.write(String(e.data));
    if (e.event === "session.updated" && (e.session as SessionInfo).id === id && (e.session as SessionInfo).status === "exited") done();
  });
  process.stdin.setRawMode(true);
  process.stdin.resume();
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (d: string) => {
    if (d === "\x1d") return done(); // Ctrl-]
    void c.request("session.input", { id, data: d });
  });
  out.on("resize", () => void c.request("session.resize", { id, ...size() }));
  await c.request("events.subscribe");
  function done(): never {
    process.stdin.setRawMode(false);
    process.stderr.write("\r\n[detached]\r\n");
    process.exit(0);
  }
  await new Promise(() => {});
}

function hooksCommand(args: string[]): void {
  const [sub, ...rest] = args;
  const fileFlag = rest.indexOf("--file");
  const file = fileFlag >= 0 ? rest[fileFlag + 1] : join(homedir(), ".claude", "settings.json");
  if (!file) fail("--file needs a path");
  let settings: Record<string, unknown> = {};
  if (existsSync(file)) {
    try {
      settings = JSON.parse(readFileSync(file, "utf8"));
    } catch {
      fail(`${file} is not valid JSON; fix it first`);
    }
  }
  if (sub === "status") {
    const events = installedEvents(settings);
    process.stdout.write(events.length ? `installed for: ${events.join(", ")}\n` : "not installed\n");
    return;
  }
  if (sub !== "install" && sub !== "uninstall") fail("hooks install|uninstall|status");
  const here = dirname(fileURLToPath(import.meta.url));
  const tasksCli = join(here, "..", "..", "tasks", "src", "cli.ts");
  const next =
    sub === "install"
      ? installHooks(settings, { event: `node "${join(here, "hook-cli.ts")}"`, sessionStart: `node "${tasksCli}" hook session-start` })
      : stripHooks(settings);
  if (JSON.stringify(next) === JSON.stringify(settings)) {
    process.stdout.write("no changes\n");
    return;
  }
  mkdirSync(dirname(file), { recursive: true });
  const backup = `${file}.shepherd-backup`;
  if (existsSync(file) && !existsSync(backup)) copyFileSync(file, backup); // keep the first, original copy
  writeFileSync(file, `${JSON.stringify(next, null, 2)}\n`);
  process.stdout.write(`${sub === "install" ? "installed into" : "removed from"} ${file}${existsSync(backup) ? ` (original kept as ${backup})` : ""}\n`);
}

async function main(): Promise<void> {
  const [cmd, ...args] = process.argv.slice(2);
  switch (cmd) {
    case "daemon":
      return runDaemon();
    case "hooks":
      return hooksCommand(args);
    case "list": {
      const c = await connect();
      const { sessions } = await c.request<{ sessions: SessionInfo[] }>("session.list");
      for (const s of sessions) {
        const a = s.attention;
        const why = a.summary ? `  (${a.summary})` : "";
        process.stdout.write(`${s.id.slice(0, 8)}  ${a.kind.padEnd(8)} ${s.status === "exited" ? "exited " : "       "} ${s.taskId ? `#${s.taskId}`.padEnd(5) : "     "} ${s.title}${why}\n`);
      }
      return c.close();
    }
    case "new": {
      let taskId: number | undefined;
      let cwd: string | undefined;
      const rest: string[] = [];
      for (let i = 0; i < args.length; i++) {
        if (args[i] === "--task") taskId = Number(args[++i]);
        else if (args[i] === "--cwd") cwd = args[++i];
        else rest.push(args[i]!);
      }
      if (taskId === undefined && !cwd) cwd = process.cwd();
      const c = await connect();
      const info = await c.request<SessionInfo>("session.create", {
        taskId,
        cwd,
        prompt: rest.join(" ") || undefined,
        cols: process.stdout.columns,
        rows: process.stdout.rows,
      });
      process.stdout.write(`${info.id}\n`);
      return c.close();
    }
    case "attach": {
      const c = await connect();
      return attach(c, await resolveId(c, args[0]));
    }
    case "peek": {
      const c = await connect();
      const { text } = await c.request<{ text: string }>("session.peek", { id: await resolveId(c, args[0]) });
      process.stdout.write(`${text}\n`);
      return c.close();
    }
    case "send":
    case "key": {
      const c = await connect();
      const id = await resolveId(c, args[0]);
      if (cmd === "send") {
        // Claude Code treats text and Enter that arrive in one chunk as a paste, so the newline
        // does not submit. Send the Enter separately, after a pause.
        await c.request("session.input", { id, data: args.slice(1).join(" ") });
        await new Promise((r) => setTimeout(r, 250));
        await c.request("session.input", { id, data: "\r" });
      } else {
        await c.request("session.input", { id, data: args.slice(1).map((k) => KEYS[k] ?? fail(`unknown key "${k}"`)).join("") });
      }
      return c.close();
    }
    case "kill": {
      const c = await connect();
      await c.request("session.kill", { id: await resolveId(c, args[0]) });
      return c.close();
    }
    default:
      process.stdout.write(USAGE);
  }
}

main().catch((e) => fail(e instanceof Error ? e.message : String(e)));
