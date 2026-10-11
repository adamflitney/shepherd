import { randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { extname, join, normalize, resolve, sep } from "node:path";
import { WebSocketServer, type WebSocket } from "ws";
import type { ClientHub } from "./hub.ts";

export interface WebOptions {
  hub: ClientHub;
  token: string;
  port?: number; // 0 picks a free port
  host?: string;
  /** Directory with the built web client. Without it only the WebSocket is served. */
  staticDir?: string;
  /** Extra Host header values to accept, e.g. a Tailscale name. */
  allowedHosts?: string[];
}

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".webmanifest": "application/manifest+json",
  ".map": "application/json",
};

/** Reads the token from `path`, creating it (mode 0600) on first use. */
export function loadOrCreateToken(path: string): string {
  if (existsSync(path)) {
    const t = readFileSync(path, "utf8").trim();
    if (t) return t;
  }
  mkdirSync(join(path, ".."), { recursive: true });
  const token = randomBytes(32).toString("hex");
  writeFileSync(path, `${token}\n`, { mode: 0o600 });
  return token;
}

/**
 * Browser access to the daemon: static client plus a WebSocket that speaks the same JSON protocol
 * as the unix socket.
 *
 * It listens on loopback, but any web page the user visits can still make requests to
 * localhost, so the WebSocket needs all of: an accepted Host header (blocks DNS rebinding), an
 * Origin that matches that host (blocks cross-site WebSocket hijacking), and the secret token.
 */
export class WebServer {
  private opts: WebOptions;
  private http: http.Server;
  private wss = new WebSocketServer({ noServer: true });
  private hosts = new Set<string>();
  private alive = new WeakSet<WebSocket>();
  private pinger: NodeJS.Timeout | undefined;

  constructor(opts: WebOptions) {
    this.opts = { ...opts, staticDir: opts.staticDir ? resolve(opts.staticDir) : undefined };
    this.http = http.createServer((req, res) => this.onRequest(req, res));
    this.http.on("upgrade", (req, socket, head) => {
      if (!this.authorize(req)) {
        socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      this.wss.handleUpgrade(req, socket, head, (ws) => this.onSocket(ws));
    });
  }

  async listen(): Promise<number> {
    const host = this.opts.host ?? "127.0.0.1";
    await new Promise<void>((resolve, reject) => {
      this.http.once("error", reject);
      this.http.listen(this.opts.port ?? 0, host, () => resolve());
    });
    const port = (this.http.address() as AddressInfo).port;
    for (const h of ["127.0.0.1", "localhost", "[::1]"]) this.hosts.add(`${h}:${port}`);
    for (const h of this.opts.allowedHosts ?? []) this.hosts.add(h);
    // drop clients that went away without closing, so viewer counts stay honest
    this.pinger = setInterval(() => {
      for (const ws of this.wss.clients) {
        if (!this.alive.has(ws)) ws.terminate();
        else {
          this.alive.delete(ws);
          ws.ping();
        }
      }
    }, 30_000);
    this.pinger.unref();
    return port;
  }

  async close(): Promise<void> {
    if (this.pinger) clearInterval(this.pinger);
    for (const ws of this.wss.clients) ws.terminate();
    this.http.closeAllConnections();
    await new Promise<void>((resolve) => this.http.close(() => resolve()));
  }

  private hostOk(req: http.IncomingMessage): boolean {
    return this.hosts.has(req.headers.host ?? "");
  }

  private authorize(req: http.IncomingMessage): boolean {
    if (!this.hostOk(req)) return false;
    const url = new URL(req.url ?? "/", "http://x");
    if (url.pathname !== "/ws") return false;
    // browsers always send Origin on WebSocket handshakes; non-browser clients may omit it
    const origin = req.headers.origin;
    if (origin !== undefined) {
      let o: URL;
      try {
        o = new URL(origin);
      } catch {
        return false;
      }
      if (!this.hosts.has(o.host)) return false;
    }
    const given = Buffer.from(url.searchParams.get("token") ?? "");
    const want = Buffer.from(this.opts.token);
    return given.length === want.length && timingSafeEqual(given, want);
  }

  private onSocket(ws: WebSocket): void {
    this.alive.add(ws);
    ws.on("pong", () => this.alive.add(ws));
    const client = this.opts.hub.connect((msg) => {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
    });
    ws.on("message", (data) => client.handle(data.toString()));
    ws.on("close", () => client.close());
    ws.on("error", () => ws.terminate());
  }

  private onRequest(req: http.IncomingMessage, res: http.ServerResponse): void {
    const deny = (code: number, text: string) => {
      res.writeHead(code, { "content-type": "text/plain" });
      res.end(text);
    };
    if (!this.hostOk(req)) return deny(403, "forbidden host");
    if (req.method !== "GET" && req.method !== "HEAD") return deny(405, "method not allowed");
    const dir = this.opts.staticDir;
    if (!dir) return deny(404, "no web client built");

    let path: string;
    try {
      path = decodeURIComponent(new URL(req.url ?? "/", "http://x").pathname);
    } catch {
      return deny(400, "bad path");
    }
    const file = normalize(join(dir, path === "/" ? "index.html" : path));
    if (file !== dir && !file.startsWith(dir + sep)) return deny(403, "forbidden");
    if (!existsSync(file) || !statSync(file).isFile()) return deny(404, "not found");
    res.writeHead(200, {
      "content-type": TYPES[extname(file)] ?? "application/octet-stream",
      "x-content-type-options": "nosniff",
      "content-security-policy": "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self' ws: wss:; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
      "cache-control": "no-cache",
    });
    res.end(req.method === "HEAD" ? undefined : readFileSync(file));
  }
}
