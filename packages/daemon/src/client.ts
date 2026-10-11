import net from "node:net";
import type { EventMessage, Response } from "./protocol.ts";

export class DaemonClient {
  private socket: net.Socket;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private listeners = new Set<(e: EventMessage) => void>();

  private constructor(socket: net.Socket) {
    this.socket = socket;
    let buf = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      buf += chunk;
      let nl: number;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.trim()) this.dispatch(JSON.parse(line) as Response | EventMessage);
      }
    });
    socket.on("close", () => {
      for (const p of this.pending.values()) p.reject(new Error("connection closed"));
      this.pending.clear();
    });
  }

  static connect(path: string): Promise<DaemonClient> {
    return new Promise((resolve, reject) => {
      const s = net.connect(path);
      s.once("connect", () => resolve(new DaemonClient(s)));
      s.once("error", reject);
    });
  }

  private dispatch(msg: Response | EventMessage): void {
    if ("event" in msg) {
      for (const l of this.listeners) l(msg);
      return;
    }
    const p = this.pending.get(msg.id);
    if (!p) return;
    this.pending.delete(msg.id);
    if ("error" in msg) p.reject(new Error(msg.error));
    else p.resolve(msg.result);
  }

  onEvent(cb: (e: EventMessage) => void): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  request<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      this.socket.write(`${JSON.stringify({ id, method, params })}\n`);
    });
  }

  close(): void {
    this.socket.destroy();
  }
}
