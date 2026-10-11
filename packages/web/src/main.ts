import "./style.css";
import { Rpc, type EventMessage } from "./rpc.ts";
import { createTerm, type TermKind, type TermView } from "./terminal.ts";

interface Attention {
  kind: "blocked" | "done" | "working" | "idle" | "unknown";
  blocker?: string;
  summary?: string;
}
interface SessionInfo {
  id: string;
  taskId?: number;
  cwd: string;
  title: string;
  status: "running" | "exited";
  exitCode?: number;
  attention: Attention;
  createdAt: number;
}

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const safe = {
  get: (k: string) => {
    try {
      return localStorage.getItem(k);
    } catch {
      return null;
    }
  },
  set: (k: string, v: string) => {
    try {
      localStorage.setItem(k, v);
    } catch {
      /* private mode: carry on without remembering */
    }
  },
};

// The link from `shepctl web` carries the token in the fragment, so it never reaches a server or a
// log. Keep it for next time and take it out of the address bar.
const fromHash = new URLSearchParams(location.hash.slice(1)).get("token");
if (fromHash) {
  safe.set("shepherd.token", fromHash);
  history.replaceState(null, "", location.pathname + location.search);
}
const token = fromHash ?? safe.get("shepherd.token");

const sessions = new Map<string, SessionInfo>();
let selected: string | undefined;
let term: TermView | undefined;
let generation = 0; // bumped on every selection so a slow attach can't clobber a newer one

const params = new URLSearchParams(location.search);
const kind: TermKind = (params.get("term") ?? safe.get("shepherd.term")) === "ghostty" ? "ghostty" : "xterm";
if (params.get("term")) safe.set("shepherd.term", kind);

function setConn(text: string, bad = false) {
  const el = $("conn");
  el.textContent = text;
  el.className = bad ? "bad" : "";
}

if (!token) {
  setConn("No access token. Open the link printed by `shepctl web`.", true);
  throw new Error("no token");
}

const rpc = new Rpc(token);

// ---- session list ---------------------------------------------------------------------------

const ORDER = { blocked: 0, done: 1, working: 2, idle: 3, unknown: 4 } as const;

function sortedSessions(): SessionInfo[] {
  return [...sessions.values()].sort((a, b) => ORDER[a.attention.kind] - ORDER[b.attention.kind] || a.createdAt - b.createdAt);
}

function describe(s: SessionInfo): string {
  const a = s.attention;
  if (s.status === "exited") return a.summary ?? "exited";
  if (a.kind === "blocked") return a.summary ?? (a.blocker === "needsPermission" ? "needs permission" : "needs an answer");
  if (a.kind === "done") return "finished";
  return a.kind === "unknown" ? s.cwd : a.kind;
}

function renderList() {
  const ul = $("sessions");
  const items = sortedSessions().map((s) => {
    const li = document.createElement("li");
    li.tabIndex = 0;
    li.dataset.id = s.id;
    if (s.id === selected) li.setAttribute("aria-current", "true");
    const dot = document.createElement("span");
    dot.className = `dot ${s.attention.kind}`;
    dot.setAttribute("role", "img");
    dot.setAttribute("aria-label", s.attention.kind);
    const title = document.createElement("span");
    title.className = "title";
    title.textContent = s.title; // titles come from the terminal, so never treat them as HTML
    const sub = document.createElement("span");
    sub.className = `sub ${s.attention.kind === "blocked" ? "blocked" : ""}`;
    sub.textContent = describe(s);
    li.append(dot, title, sub);
    return li;
  });
  ul.replaceChildren(...items);
  if (!items.length) {
    const li = document.createElement("li");
    li.className = "sub";
    li.style.gridTemplateColumns = "1fr";
    li.textContent = "No sessions yet.";
    ul.append(li);
  }
}

$("sessions").addEventListener("click", (e) => {
  const id = (e.target as HTMLElement).closest("li")?.dataset.id;
  if (id) void select(id);
});
$("sessions").addEventListener("keydown", (e) => {
  const id = (e.target as HTMLElement).closest("li")?.dataset.id;
  if (id && (e.key === "Enter" || e.key === " ")) {
    e.preventDefault();
    void select(id);
  }
});

function renderBar() {
  const s = selected ? sessions.get(selected) : undefined;
  $("empty").hidden = !!s;
  $("term").style.visibility = s ? "visible" : "hidden";
  $("bar-title").textContent = s?.title ?? "";
  $("bar-note").textContent = s ? (s.status === "exited" ? `exited${s.exitCode ? ` (code ${s.exitCode})` : ""}` : s.cwd) : "";
  const stop = $<HTMLButtonElement>("kill");
  stop.hidden = !s;
  stop.textContent = s?.status === "exited" ? "Remove" : "Stop";
}

// ---- terminal -------------------------------------------------------------------------------

async function ensureTerm(): Promise<TermView> {
  if (term) return term;
  const t = await createTerm(kind, $("term"));
  t.onData((data) => {
    if (selected) void rpc.request("session.input", { id: selected, data }).catch(() => {});
  });
  t.onResize(({ cols, rows }) => {
    if (selected) void rpc.request("session.resize", { id: selected, cols, rows }).catch(() => {});
  });
  t.onKey((e) => shortcut(e)); // our shortcuts must not also be typed into the agent
  new ResizeObserver(() => {
    if (selected) t.fit();
  }).observe($("term"));
  term = t;
  return t;
}

async function select(id: string) {
  const gen = ++generation;
  const previous = selected;
  selected = id;
  renderList();
  renderBar();
  const t = await ensureTerm();
  if (previous && previous !== id) void rpc.request("session.detach", { id: previous }).catch(() => {});
  t.reset();
  try {
    // resize first so the snapshot is taken at the size we will draw it at
    const { cols, rows } = t.fit();
    await rpc.request("session.resize", { id, cols, rows });
    const { snapshot } = await rpc.request<{ snapshot: string }>("session.attach", { id });
    if (gen !== generation) return;
    t.write(snapshot);
    t.focus();
    safe.set("shepherd.last", id);
  } catch (e) {
    if (gen === generation) t.write(`\r\n\x1b[31m${(e as Error).message}\x1b[0m\r\n`);
  }
}

function onEvent(e: EventMessage) {
  switch (e.event) {
    case "session.data":
      if (e.id === selected) term?.write(String(e.data));
      break;
    case "session.created":
    case "session.updated": {
      const s = e.session as SessionInfo;
      sessions.set(s.id, s);
      renderList();
      if (s.id === selected) renderBar();
      break;
    }
    case "session.removed":
      sessions.delete(String(e.id));
      if (selected === e.id) {
        selected = sortedSessions()[0]?.id;
        term?.reset();
        if (selected) void select(selected);
      }
      renderList();
      renderBar();
      break;
  }
}

rpc.onEvent = onEvent;
rpc.onStatus = (s) => {
  if (s === "open") setConn("connected");
  else if (s === "unauthorized") setConn("Refused: the token is wrong or out of date. Open a fresh link from `shepctl web`.", true);
  else setConn(s === "connecting" ? "connecting…" : "disconnected, retrying…", s === "closed");
};
rpc.onOpen = async () => {
  const { sessions: list } = await rpc.request<{ sessions: SessionInfo[] }>("events.subscribe");
  sessions.clear();
  for (const s of list) sessions.set(s.id, s);
  const wanted = params.get("select");
  if (!selected && wanted && sessions.has(wanted)) selected = wanted;
  if (!selected) {
    const last = safe.get("shepherd.last");
    const first = (last && sessions.has(last) ? last : undefined) ?? sortedSessions()[0]?.id;
    if (first) selected = first;
  }
  renderList();
  if (selected && sessions.has(selected)) await select(selected); // also re-attaches after a reconnect
  else renderBar();
};

// ---- actions --------------------------------------------------------------------------------

const dlg = $<HTMLDialogElement>("dlg");
const form = $<HTMLFormElement>("new-form");

function openNew() {
  $("form-error").textContent = "";
  (form.elements.namedItem("cwd") as HTMLInputElement).value ||= safe.get("shepherd.cwd") ?? "";
  dlg.showModal();
  (form.elements.namedItem("task") as HTMLInputElement).focus();
}
$("new").addEventListener("click", openNew);
$("cancel").addEventListener("click", () => dlg.close());
form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = new FormData(form);
  const task = String(f.get("task") ?? "").trim();
  const cwd = String(f.get("cwd") ?? "").trim();
  const prompt = String(f.get("prompt") ?? "").trim();
  if (!task && !cwd) return void ($("form-error").textContent = "Enter a task number or a directory.");
  try {
    const t = await ensureTerm();
    const { cols, rows } = t.fit();
    const info = await rpc.request<SessionInfo>("session.create", {
      ...(task ? { taskId: Number(task) } : {}),
      ...(cwd ? { cwd } : {}),
      ...(prompt ? { prompt } : {}),
      cols,
      rows,
    });
    if (cwd) safe.set("shepherd.cwd", cwd);
    dlg.close();
    form.reset();
    sessions.set(info.id, info);
    await select(info.id);
  } catch (err) {
    $("form-error").textContent = (err as Error).message;
  }
});

$("kill").addEventListener("click", () => {
  const s = selected ? sessions.get(selected) : undefined;
  if (!s) return;
  // a running session is stopped first; once it has exited the same button forgets it
  void rpc.request(s.status === "exited" ? "session.remove" : "session.kill", { id: s.id }).catch(() => {});
});

/** Alt+Up/Down switch sessions, Alt+N starts one. Returns true if the key was ours. */
function shortcut(e: KeyboardEvent): boolean {
  if (!e.altKey || e.ctrlKey || e.metaKey || e.type !== "keydown") return false;
  const list = sortedSessions();
  const at = list.findIndex((s) => s.id === selected);
  let target: string | undefined;
  if (e.code === "ArrowDown") target = list[Math.min(list.length - 1, at + 1)]?.id;
  else if (e.code === "ArrowUp") target = list[Math.max(0, at - 1)]?.id;
  else if (e.code === "KeyN") {
    openNew();
    return true;
  } else return false;
  if (target && target !== selected) void select(target);
  return true;
}
window.addEventListener(
  "keydown",
  (e) => {
    if (shortcut(e)) {
      e.preventDefault();
      e.stopPropagation();
    }
  },
  true,
);

// the desktop shell asks an already-open dashboard to switch session
window.addEventListener("shepherd-select", (e) => {
  const id = (e as CustomEvent<string>).detail;
  if (sessions.has(id)) void select(id);
});

renderList();
renderBar();
rpc.connect();
