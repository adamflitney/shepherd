import type { HookPayload } from "./attention.ts";
import type { SessionManager } from "./manager.ts";
import type { EventMessage, Request, Response } from "./protocol.ts";

export type Outgoing = Response | EventMessage;

/**
 * Transport-independent protocol endpoint: the unix socket and the WebSocket server both feed
 * their messages through here, so a browser tab can do everything shepherdctl can.
 */
export class ClientHub {
  readonly manager: SessionManager;
  private clients = new Set<Client>();

  constructor(manager: SessionManager) {
    this.manager = manager;
    manager.onEvent((e) => {
      const msg: EventMessage = { event: e.type, ...("session" in e ? { session: e.session } : { id: e.id }) };
      for (const c of this.clients) if (c.subscribed) c.send(msg);
    });
  }

  connect(send: (msg: Outgoing) => void): Client {
    const client = new Client(this.manager, send, (c) => this.clients.delete(c));
    this.clients.add(client);
    return client;
  }

  closeAll(): void {
    for (const c of [...this.clients]) c.close();
  }
}

export class Client {
  subscribed = false;
  readonly send: (msg: Outgoing) => void;
  private manager: SessionManager;
  private attached = new Map<string, () => void>(); // session id -> stop listening
  private onClose: (c: Client) => void;

  constructor(manager: SessionManager, send: (msg: Outgoing) => void, onClose: (c: Client) => void) {
    this.manager = manager;
    this.send = send;
    this.onClose = onClose;
  }

  /** Handle one JSON message. Never throws: problems come back as error responses. */
  handle(line: string): void {
    let req: Request;
    try {
      req = JSON.parse(line) as Request;
    } catch {
      return this.send({ id: 0, error: "invalid JSON" });
    }
    try {
      this.send({ id: req.id, result: this.call(req.method, req.params ?? {}) });
    } catch (e) {
      this.send({ id: req.id, error: e instanceof Error ? e.message : String(e) });
    }
  }

  close(): void {
    for (const stop of this.attached.values()) stop();
    this.attached.clear();
    this.onClose(this);
  }

  private call(method: string, p: Record<string, unknown>): unknown {
    const m = this.manager;
    const id = () => {
      if (typeof p.id !== "string") throw new Error("id is required");
      return p.id;
    };
    switch (method) {
      case "ping":
        return { pid: process.pid };
      case "events.subscribe":
        this.subscribed = true;
        return { sessions: m.list() };
      case "hook.event":
        return { handled: m.handleHook((p.payload ?? {}) as HookPayload, typeof p.shepherdSessionId === "string" ? p.shepherdSessionId : undefined) };
      case "session.list":
        return { sessions: m.list() };
      case "session.create":
        return m.create(p);
      case "session.attach": {
        const s = m.get(id());
        this.attached.get(s.id)?.();
        const sessionId = s.id;
        s.viewerAttached();
        // snapshot and listener are set up in the same tick, so no output is lost or repeated
        const snapshot = s.snapshot();
        const unlisten = s.onData((data) => this.send({ event: "session.data", id: sessionId, data }));
        this.attached.set(sessionId, () => {
          unlisten();
          s.viewerDetached();
        });
        return { snapshot, session: s.info };
      }
      case "session.detach":
        this.attached.get(id())?.();
        this.attached.delete(id());
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
