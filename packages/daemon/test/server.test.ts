import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TaskStore } from "@shepherd/tasks";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DaemonClient } from "../src/client.ts";
import { SessionManager } from "../src/manager.ts";
import type { SessionInfo } from "../src/session.ts";
import { DaemonServer } from "../src/server.ts";
import { fakeAgent, waitFor } from "./helpers.ts";

let server: DaemonServer;
let manager: SessionManager;
let path: string;
let work: string;
const clients: DaemonClient[] = [];

async function connect() {
  const c = await DaemonClient.connect(path);
  clients.push(c);
  return c;
}

beforeEach(async () => {
  const dir = mkdtempSync(join(tmpdir(), "shep-"));
  path = join(dir, "s.sock");
  work = mkdtempSync(join(tmpdir(), "shep-work-"));
  manager = new SessionManager({ store: new TaskStore(join(dir, "tasks")), agent: fakeAgent(), env: { PATH: process.env.PATH } });
  server = new DaemonServer(manager, path);
  await server.listen();
});
afterEach(async () => {
  for (const c of clients.splice(0)) c.close();
  manager.shutdown();
  await server.close();
});

describe("DaemonServer", () => {
  it("creates a session, attaches with a snapshot, and streams input and output", async () => {
    const c = await connect();
    expect(await c.request("ping")).toHaveProperty("pid");
    const info = await c.request<SessionInfo>("session.create", { cwd: work });
    await waitFor(() => manager.get(info.id).peek().includes("ARGS:"), "agent output");

    const attached = await c.request<{ snapshot: string }>("session.attach", { id: info.id });
    expect(attached.snapshot).toContain("ARGS:"); // what was already on screen is replayed
    let streamed = "";
    c.onEvent((e) => e.event === "session.data" && (streamed += e.data));
    await c.request("session.input", { id: info.id, data: "ping-pong\r" });
    await waitFor(() => streamed.includes("ping-pong"), "streamed echo");

    const { text } = await c.request<{ text: string }>("session.peek", { id: info.id });
    expect(text).toContain("ping-pong");
  });

  it("a second client attaching later gets the earlier output in its snapshot", async () => {
    const a = await connect();
    const info = await a.request<SessionInfo>("session.create", { cwd: work });
    await a.request("session.input", { id: info.id, data: "first-client-line\r" });
    await waitFor(() => manager.get(info.id).peek().includes("first-client-line"), "echo");
    const b = await connect();
    const { snapshot } = await b.request<{ snapshot: string }>("session.attach", { id: info.id });
    expect(snapshot).toContain("first-client-line");
  });

  it("only streams data to clients that attached", async () => {
    const a = await connect();
    const b = await connect();
    const info = await a.request<SessionInfo>("session.create", { cwd: work });
    await a.request("session.attach", { id: info.id });
    let aGot = "";
    let bGot = "";
    a.onEvent((e) => e.event === "session.data" && (aGot += e.data));
    b.onEvent((e) => e.event === "session.data" && (bGot += e.data));
    await a.request("session.input", { id: info.id, data: "only-a\r" });
    await waitFor(() => aGot.includes("only-a"), "a output");
    expect(bGot).toBe("");
    await a.request("session.detach", { id: info.id });
    aGot = "";
    await a.request("session.input", { id: info.id, data: "after-detach\r" });
    await waitFor(() => manager.get(info.id).peek().includes("after-detach"), "echo");
    expect(aGot).toBe("");
  });

  it("pushes session events to subscribers, including exit", async () => {
    const c = await connect();
    const events: string[] = [];
    c.onEvent((e) => events.push(e.event));
    await c.request("events.subscribe");
    const info = await c.request<SessionInfo>("session.create", { cwd: work });
    await c.request("session.kill", { id: info.id });
    await waitFor(() => events.includes("session.updated") && manager.get(info.id).status === "exited", "exit event");
    expect(events[0]).toBe("session.created");
    const { sessions } = await c.request<{ sessions: SessionInfo[] }>("session.list");
    expect(sessions[0]?.status).toBe("exited");
  });

  it("resizes the session", async () => {
    const c = await connect();
    const info = await c.request<SessionInfo>("session.create", { cwd: work });
    await c.request("session.resize", { id: info.id, cols: 90, rows: 20 });
    expect(manager.get(info.id).info).toMatchObject({ cols: 90, rows: 20 });
  });

  it("returns errors instead of dropping the connection", async () => {
    const c = await connect();
    await expect(c.request("nope")).rejects.toThrow(/unknown method/);
    await expect(c.request("session.peek", { id: "missing" })).rejects.toThrow(/no session/);
    await expect(c.request("session.create", { taskId: 5 })).rejects.toThrow(/no task 5/);
    expect(await c.request("ping")).toBeTruthy();
  });

  it("refuses to start twice, but replaces a stale socket", async () => {
    await expect(new DaemonServer(manager, path).listen()).rejects.toThrow(/already running/);
    await server.close();
    writeFileSync(path, ""); // a crashed daemon leaves its socket file behind
    server = new DaemonServer(manager, path);
    await server.listen();
    expect(await (await connect()).request("ping")).toBeTruthy();
  });
});
