import { chmodSync, existsSync, unlinkSync } from "node:fs";
import net from "node:net";
import type { HookPayload } from "./attention.ts";
import { SessionManager } from "./manager.ts";
import type { EventMessage, Request, Response } from "./protocol.ts";

interface Conn {
  socket: net.Socket;
  subscribed: boolean;
  attached: Map<string, () => void>; // session id -> stop listening
}

export class DaemonServer {
  private server = net.createServer((socket) => this.accept(socket));
  private conns = new Set<Conn>();
  readonly manager: SessionManager;
  readonly socketPath: string;

  constructor(manager: SessionManager, socketPath: string) {
    this.manager = manager;
    this.socketPath = socketPath;
    manager.onEvent((e) => {
      const msg: EventMessage = { event: e.type, ...("session" in e ? { session: e.session } : { id: e.id }) };
      for (const c of this.conns) if (c.subscribed) send(c.socket, msg);
    });
  }

  async listen(): Promise<void> {
    if (existsSync(this.socketPath)) {
      if (await isAlive(this.socketPath)) throw new Error(`a daemon is already running on ${this.socketPath}`);
      unlinkSync(this.socketPath); // stale socket from a crashed daemon
    }
    await new Promise<void>((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(this.socketPath, () => resolve());
    });
    chmodSync(this.socketPath, 0o600); // the file permissions are the authentication
  }

  async close(): Promise<void> {
    for (const c of this.conns) c.socket.destroy();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
    if (existsSync(this.socketPath)) unlinkSync(this.socketPath);
  }

  private accept(socket: net.Socket): void {
    const conn: Conn = { socket, subscribed: false, attached: new Map() };
    this.conns.add(conn);
    let buf = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      buf += chunk;
      let nl: number;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.trim()) this.handle(conn, line);
      }
    });
    const cleanup = () => {
      for (const stop of conn.attached.values()) stop();
      conn.attached.clear();
      this.conns.delete(conn);
    };
    socket.on("close", cleanup);
    socket.on("error", () => socket.destroy());
  }

  private handle(conn: Conn, line: string): void {
    let req: Request;
    try {
      req = JSON.parse(line) as Request;
    } catch {
      return send(conn.socket, { id: 0, error: "invalid JSON" });
    }
    try {
      send(conn.socket, { id: req.id, result: this.call(conn, req.method, req.params ?? {}) });
    } catch (e) {
      send(conn.socket, { id: req.id, error: e instanceof Error ? e.message : String(e) });
    }
  }

  private call(conn: Conn, method: string, p: Record<string, unknown>): unknown {
    const m = this.manager;
    const id = () => {
      if (typeof p.id !== "string") throw new Error("id is required");
      return p.id;
    };
    switch (method) {
      case "ping":
        return { pid: process.pid };
      case "events.subscribe":
        conn.subscribed = true;
        return { sessions: m.list() };
      case "hook.event":
        return { handled: m.handleHook((p.payload ?? {}) as HookPayload, typeof p.shepherdSessionId === "string" ? p.shepherdSessionId : undefined) };
      case "session.list":
        return { sessions: m.list() };
      case "session.create":
        return m.create(p);
      case "session.attach": {
        const s = m.get(id());
        conn.attached.get(s.id)?.();
        const sessionId = s.id;
        s.viewerAttached();
        // snapshot and listener are set up in the same tick, so no output is lost or repeated
        const snapshot = s.snapshot();
        const unlisten = s.onData((data) => send(conn.socket, { event: "session.data", id: sessionId, data }));
        conn.attached.set(sessionId, () => {
          unlisten();
          s.viewerDetached();
        });
        return { snapshot, session: s.info };
      }
      case "session.detach":
        conn.attached.get(id())?.();
        conn.attached.delete(id());
        return {};
      case "session.input":
        m.get(id()).write(String(p.data ?? ""));
        return {};
      case "session.resize":
        m.get(id()).resize(Number(p.cols), Number(p.rows));
        return {};
      case "session.peek":
        return { text: m.get(id()).peek() };
      case "session.kill":
        m.get(id()).kill();
        return {};
      case "session.remove":
        m.remove(id());
        return {};
      default:
        throw new Error(`unknown method ${method}`);
    }
  }
}

function send(socket: net.Socket, msg: Response | EventMessage): void {
  if (!socket.destroyed) socket.write(`${JSON.stringify(msg)}\n`);
}

function isAlive(path: string): Promise<boolean> {
  return new Promise((resolve) => {
    const s = net.connect(path);
    s.once("connect", () => {
      s.destroy();
      resolve(true);
    });
    s.once("error", () => resolve(false));
  });
}
