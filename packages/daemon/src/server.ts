import { chmodSync, existsSync, unlinkSync } from "node:fs";
import net from "node:net";
import { ClientHub, type Client, type Outgoing } from "./hub.ts";
import type { SessionManager } from "./manager.ts";

/** NDJSON over a unix socket; the file permissions are the authentication. */
export class DaemonServer {
  private server = net.createServer((socket) => this.accept(socket));
  private sockets = new Set<net.Socket>();
  readonly manager: SessionManager;
  readonly socketPath: string;
  readonly hub: ClientHub;

  constructor(manager: SessionManager, socketPath: string, hub: ClientHub = new ClientHub(manager)) {
    this.manager = manager;
    this.socketPath = socketPath;
    this.hub = hub;
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
    chmodSync(this.socketPath, 0o600);
  }

  async close(): Promise<void> {
    for (const s of this.sockets) s.destroy();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
    if (existsSync(this.socketPath)) unlinkSync(this.socketPath);
  }

  private accept(socket: net.Socket): void {
    this.sockets.add(socket);
    const client: Client = this.hub.connect((msg: Outgoing) => {
      if (!socket.destroyed) socket.write(`${JSON.stringify(msg)}\n`);
    });
    let buf = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      buf += chunk;
      let nl: number;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.trim()) client.handle(line);
      }
    });
    socket.on("close", () => {
      this.sockets.delete(socket);
      client.close();
    });
    socket.on("error", () => socket.destroy());
  }
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
