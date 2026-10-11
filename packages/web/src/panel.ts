import "./panel.css";
import { Rpc, type EventMessage } from "./rpc.ts";

// The quick-switcher panel. In the desktop app it is a hidden, preloaded window that a global
// hotkey shows; it also works in a plain browser tab (panel.html) for development.

interface SessionInfo {
  id: string;
  title: string;
  cwd: string;
  status: "running" | "exited";
  taskId?: number;
  attention: { kind: "blocked" | "done" | "working" | "idle" | "unknown"; summary?: string; blocker?: string };
  createdAt: number;
}
interface Desktop {
  hide(): void;
  openSession(id: string): void;
  shown(): void;
  onShow(cb: () => void): void;
}
declare global {
  interface Window {
    shepherdDesktop?: Desktop;
  }
}

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const desktop = window.shepherdDesktop;

const fromHash = new URLSearchParams(location.hash.slice(1)).get("token");
const stored = (() => {
  try {
    return localStorage.getItem("shepherd.token");
  } catch {
    return null;
  }
})();
const token = fromHash ?? stored;
if (fromHash) {
  try {
    localStorage.setItem("shepherd.token", fromHash);
  } catch {
    /* fine */
  }
}

const sessions = new Map<string, SessionInfo>();
let query = "";
let cursor = 0;

const ORDER = { blocked: 0, done: 1, working: 2, idle: 3, unknown: 4 } as const;

/** Every character of the query must appear in order (case-insensitive), like a quick switcher. */
export function matches(q: string, text: string): boolean {
  let i = 0;
  const t = text.toLowerCase();
  for (const c of q.toLowerCase()) {
    i = t.indexOf(c, i);
    if (i === -1) return false;
    i++;
  }
  return true;
}

function visible(): SessionInfo[] {
  return [...sessions.values()]
    .filter((s) => matches(query, `${s.title} ${s.cwd} ${s.taskId ? `#${s.taskId}` : ""}`))
    .sort((a, b) => ORDER[a.attention.kind] - ORDER[b.attention.kind] || a.createdAt - b.createdAt);
}

function sub(s: SessionInfo): string {
  const a = s.attention;
  if (s.status === "exited") return a.summary ?? "exited";
  if (a.kind === "blocked") return a.summary ?? (a.blocker === "needsPermission" ? "needs permission" : "needs an answer");
  if (a.kind === "done") return "finished";
  return a.kind === "unknown" ? s.cwd : a.kind;
}

function render() {
  const items = visible();
  cursor = Math.min(cursor, Math.max(0, items.length - 1));
  const nodes = items.map((s, i) => {
    const li = document.createElement("li");
    li.setAttribute("role", "option");
    li.setAttribute("aria-selected", String(i === cursor));
    li.dataset.id = s.id;
    const dot = document.createElement("span");
    dot.className = `dot ${s.attention.kind}`;
    const title = document.createElement("span");
    title.className = "title";
    title.textContent = s.title; // terminal-provided, so text only
    const note = document.createElement("span");
    note.className = `sub ${s.attention.kind === "blocked" ? "blocked" : ""}`;
    note.textContent = sub(s);
    li.append(dot, title, note);
    return li;
  });
  if (!nodes.length) {
    const li = document.createElement("li");
    li.className = "empty";
    li.textContent = sessions.size ? "No match" : "No sessions";
    nodes.push(li);
  }
  $("list").replaceChildren(...nodes);
  $("list").querySelector('[aria-selected="true"]')?.scrollIntoView({ block: "nearest" });
}

function open(id: string | undefined) {
  if (!id) return;
  if (desktop) desktop.openSession(id);
  else location.href = `/?select=${encodeURIComponent(id)}`;
}

function reset() {
  query = "";
  cursor = 0;
  $<HTMLInputElement>("q").value = "";
  render();
  $<HTMLInputElement>("q").focus();
}

$<HTMLInputElement>("q").addEventListener("input", (e) => {
  query = (e.target as HTMLInputElement).value;
  cursor = 0;
  render();
});
window.addEventListener("keydown", (e) => {
  const items = visible();
  if (e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")) cursor = Math.min(items.length - 1, cursor + 1);
  else if (e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")) cursor = Math.max(0, cursor - 1);
  else if (e.key === "Enter") return open(items[cursor]?.id);
  else if (e.key === "Escape") return desktop?.hide();
  else return;
  e.preventDefault();
  render();
});
$("list").addEventListener("click", (e) => open((e.target as HTMLElement).closest("li")?.dataset.id));

function status(text: string, bad = false) {
  const el = $("status");
  el.textContent = text;
  el.className = bad ? "bad" : "";
}

desktop?.onShow(() => {
  reset();
  desktop.shown();
});

if (!token) {
  status("no token", true);
} else {
  const rpc = new Rpc(token);
  rpc.onStatus = (s) => status(s === "open" ? "" : s === "unauthorized" ? "refused: bad token" : "reconnecting…", s !== "open" && s !== "connecting");
  rpc.onEvent = (e: EventMessage) => {
    if (e.event === "session.created" || e.event === "session.updated") sessions.set((e.session as SessionInfo).id, e.session as SessionInfo);
    else if (e.event === "session.removed") sessions.delete(String(e.id));
    else return;
    render();
  };
  rpc.onOpen = async () => {
    const { sessions: list } = await rpc.request<{ sessions: SessionInfo[] }>("events.subscribe");
    sessions.clear();
    for (const s of list) sessions.set(s.id, s);
    render();
  };
  rpc.connect();
}
render();
$<HTMLInputElement>("q").focus();
