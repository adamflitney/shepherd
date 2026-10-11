import { mkdirSync, mkdtempSync, statSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TaskStore } from "@shepherd/tasks";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { ClientHub } from "../src/hub.ts";
import { SessionManager } from "../src/manager.ts";
import { loadOrCreateToken, WebServer } from "../src/web.ts";
import { fakeAgent, waitFor } from "./helpers.ts";

const TOKEN = "s3cret-token";
let manager: SessionManager;
let web: WebServer;
let port: number;
let dir: string;
let work: string;
const sockets: WebSocket[] = [];

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), "shep-web-"));
  work = mkdtempSync(join(tmpdir(), "shep-work-"));
  mkdirSync(join(dir, "dist"));
  writeFileSync(join(dir, "dist", "index.html"), "<h1>shepherd</h1>");
  writeFileSync(join(dir, "secret.txt"), "do not serve");
  manager = new SessionManager({ store: new TaskStore(join(dir, "tasks")), agent: fakeAgent(), env: { PATH: process.env.PATH } });
  web = new WebServer({ hub: new ClientHub(manager), token: TOKEN, staticDir: join(dir, "dist") });
  port = await web.listen();
});
afterEach(async () => {
  for (const s of sockets.splice(0)) s.terminate();
  manager.shutdown();
  await web.close();
});

/** Resolves with the open socket, or with the HTTP status if the handshake was refused. */
function open(opts: { token?: string | null; origin?: string | null; host?: string } = {}): Promise<WebSocket | number> {
  const token = opts.token === undefined ? TOKEN : opts.token;
  const headers: Record<string, string> = {};
  if (opts.origin !== null) headers.Origin = opts.origin ?? `http://127.0.0.1:${port}`;
  if (opts.host) headers.Host = opts.host;
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws${token === null ? "" : `?token=${token}`}`, { headers });
  sockets.push(ws);
  return new Promise((resolve) => {
    ws.once("open", () => resolve(ws));
    ws.once("unexpected-response", (_req, res) => resolve(res.statusCode ?? 0));
    ws.once("error", () => resolve(0));
  });
}

function rpc(ws: WebSocket) {
  let n = 0;
  const pending = new Map<number, (m: Record<string, unknown>) => void>();
  const events: Record<string, unknown>[] = [];
  ws.on("message", (d) => {
    const m = JSON.parse(d.toString());
    if ("event" in m) events.push(m);
    else pending.get(m.id)?.(m);
  });
  const request = (method: string, params: Record<string, unknown> = {}) =>
    new Promise<Record<string, unknown>>((resolve) => {
      const id = ++n;
      pending.set(id, resolve);
      ws.send(JSON.stringify({ id, method, params }));
    });
  return { request, events };
}

function get(path: string, opts: { host?: string; method?: string } = {}): Promise<{ status: number; body: string; headers: http.IncomingHttpHeaders }> {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path, method: opts.method ?? "GET", headers: opts.host ? { Host: opts.host } : {} }, (res) => {
      let body = "";
      res.on("data", (c) => (body += c));
      res.on("end", () => resolve({ status: res.statusCode ?? 0, body, headers: res.headers }));
    });
    req.on("error", reject);
    req.end();
  });
}

describe("WebSocket access", () => {
  it("lets a browser create a session, attach and stream, like the unix socket", async () => {
    const ws = (await open()) as WebSocket;
    const { request, events } = rpc(ws);
    const created = (await request("session.create", { cwd: work })).result as { id: string };
    await waitFor(() => manager.get(created.id).peek().includes("ARGS:"), "agent output");
    const attached = (await request("session.attach", { id: created.id })).result as { snapshot: string };
    expect(attached.snapshot).toContain("ARGS:");
    await request("session.input", { id: created.id, data: "from-browser\r" });
    await waitFor(() => events.some((e) => e.event === "session.data" && String(e.data).includes("from-browser")), "streamed echo");
  });

  it("counts a browser tab as a viewer and stops when it closes", async () => {
    const ws = (await open()) as WebSocket;
    const { request } = rpc(ws);
    const id = ((await request("session.create", { cwd: work })).result as { id: string }).id;
    await request("session.attach", { id });
    expect(manager.get(id).viewers).toBe(1);
    ws.close();
    await waitFor(() => manager.get(id).viewers === 0, "viewer cleanup");
  });

  it("accepts a client that sends no Origin (non-browser) as long as the token is right", async () => {
    expect(await open({ origin: null })).toBeInstanceOf(WebSocket);
  });

  it("refuses a wrong or missing token", async () => {
    expect(await open({ token: "nope" })).toBe(403);
    expect(await open({ token: null })).toBe(403);
  });

  it("refuses a cross-site Origin even with the right token", async () => {
    expect(await open({ origin: "https://evil.example" })).toBe(403);
    expect(await open({ origin: "http://127.0.0.1:1" })).toBe(403);
    expect(await open({ origin: "not a url" })).toBe(403);
  });

  it("refuses an unexpected Host header (DNS rebinding)", async () => {
    expect(await open({ host: "evil.example", origin: "http://evil.example" })).toBe(403);
    expect(await open({ host: `evil.example:${port}`, origin: null })).toBe(403);
  });

  it("accepts configured extra hosts", async () => {
    await web.close();
    web = new WebServer({ hub: new ClientHub(manager), token: TOKEN, allowedHosts: ["mac.tail1234.ts.net"] });
    port = await web.listen();
    expect(await open({ host: "mac.tail1234.ts.net", origin: "https://mac.tail1234.ts.net" })).toBeInstanceOf(WebSocket);
  });
});

describe("static files", () => {
  it("serves the client with hardening headers", async () => {
    const r = await get("/");
    expect(r).toMatchObject({ status: 200, body: "<h1>shepherd</h1>" });
    expect(r.headers["content-type"]).toContain("text/html");
    expect(r.headers["content-security-policy"]).toContain("object-src 'none'");
    expect(r.headers["x-content-type-options"]).toBe("nosniff");
  });

  it("404s missing files and refuses path traversal", async () => {
    expect((await get("/missing.js")).status).toBe(404);
    for (const p of ["/../secret.txt", "/%2e%2e/secret.txt", "/..%2fsecret.txt", "/%00"]) {
      const r = await get(p);
      expect(r.body).not.toContain("do not serve");
      expect(r.status).toBeGreaterThanOrEqual(400);
    }
  });

  it("refuses bad hosts and non-GET methods", async () => {
    expect((await get("/", { host: "evil.example" })).status).toBe(403);
    expect((await get("/", { method: "POST" })).status).toBe(405);
  });
});

describe("loadOrCreateToken", () => {
  it("creates a private token once and reuses it", () => {
    const path = join(dir, "web-token");
    const a = loadOrCreateToken(path);
    expect(a).toMatch(/^[0-9a-f]{64}$/);
    expect(loadOrCreateToken(path)).toBe(a);
    expect(statSync(path).mode & 0o777).toBe(0o600);
  });
});
