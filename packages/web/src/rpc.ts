export interface EventMessage {
  event: string;
  [key: string]: unknown;
}

type Status = "connecting" | "open" | "closed" | "unauthorized";

/** JSON request/response + events over the daemon's WebSocket, reconnecting with backoff. */
export class Rpc {
  private ws: WebSocket | undefined;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private retry = 0;
  private stopped = false;
  onEvent: (e: EventMessage) => void = () => {};
  onStatus: (s: Status) => void = () => {};
  /** Called after every (re)connect, before requests queued by the app are sent. */
  onOpen: () => Promise<void> | void = () => {};
  private token: string;

  constructor(token: string) {
    this.token = token;
  }

  connect(): void {
    this.onStatus("connecting");
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const ws = new WebSocket(`${proto}://${location.host}/ws?token=${encodeURIComponent(this.token)}`);
    this.ws = ws;
    let opened = false;
    ws.onopen = () => {
      opened = true;
      this.retry = 0;
      this.onStatus("open");
      void this.onOpen();
    };
    ws.onmessage = (m) => {
      const msg = JSON.parse(String(m.data));
      if ("event" in msg) return this.onEvent(msg as EventMessage);
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if ("error" in msg) p.reject(new Error(msg.error));
      else p.resolve(msg.result);
    };
    ws.onclose = () => {
      for (const p of this.pending.values()) p.reject(new Error("disconnected"));
      this.pending.clear();
      if (this.stopped) return;
      // a refused handshake never opens: that is a bad token (or host), not a network blip
      if (!opened && this.retry >= 2) return this.onStatus("unauthorized");
      this.onStatus("closed");
      setTimeout(() => this.connect(), Math.min(5000, 300 * 2 ** this.retry++));
    };
  }

  request<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return Promise.reject(new Error("not connected"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });
  }
}
