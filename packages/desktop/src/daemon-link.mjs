import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";

export function config() {
  const home = process.env.SHEPHERD_HOME ?? join(homedir(), ".shepherd");
  const port = Number(process.env.SHEPHERD_WEB_PORT) || 7330;
  let token = null;
  try {
    token = readFileSync(join(home, "web-token"), "utf8").trim();
  } catch {
    /* daemon never started */
  }
  return { home, port, token, origin: `http://127.0.0.1:${port}` };
}

/** Keeps a live copy of the daemon's session list (for the menu bar), reconnecting forever. */
export function watchSessions(cfg, onChange) {
  const sessions = new Map();
  let ws;
  let retry = 0;
  let stopped = false;
  const connect = () => {
    if (stopped || !cfg.token) return onChange(sessions, "no-token");
    ws = new WebSocket(`ws://127.0.0.1:${cfg.port}/ws?token=${encodeURIComponent(cfg.token)}`);
    ws.on("open", () => {
      retry = 0;
      ws.send(JSON.stringify({ id: 1, method: "events.subscribe" }));
    });
    ws.on("message", (raw) => {
      const m = JSON.parse(raw.toString());
      if (m.id === 1 && m.result) {
        sessions.clear();
        for (const s of m.result.sessions) sessions.set(s.id, s);
      } else if (m.event === "session.created" || m.event === "session.updated") sessions.set(m.session.id, m.session);
      else if (m.event === "session.removed") sessions.delete(m.id);
      else return;
      onChange(sessions, "connected");
    });
    const lost = () => {
      sessions.clear();
      onChange(sessions, "offline");
      if (!stopped) setTimeout(connect, Math.min(5000, 500 * 2 ** retry++));
    };
    ws.on("close", lost);
    ws.on("error", () => ws.terminate());
  };
  connect();
  return () => {
    stopped = true;
    ws?.terminate();
  };
}

/** Name of the frontmost application, via lsappinfo (read-only, needs no permissions). */
export async function frontmostApp() {
  const { execFile } = await import("node:child_process");
  const run = (args) =>
    new Promise((resolve) => execFile("/usr/bin/lsappinfo", args, (err, out) => resolve(err ? "" : out.trim())));
  const asn = await run(["front"]);
  if (!asn) return "unknown";
  const info = await run(["info", "-only", "name", asn]);
  return /"LSDisplayName"="([^"]*)"/.exec(info)?.[1] ?? info;
}
