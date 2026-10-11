import { app, BrowserWindow, globalShortcut, ipcMain, nativeImage, screen, Tray } from "electron";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { config, frontmostApp, watchSessions } from "./daemon-link.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const cfg = config();
const HOTKEY = process.env.SHEPHERD_HOTKEY ?? "Control+Alt+Command+Shift+W"; // Hyper+W
const SPIKE = !!process.env.SHEPHERD_SPIKE;
const log = (tag, data) => process.env.SHEPHERD_SPIKE && console.log(`SPIKE ${tag} ${JSON.stringify(data)}`);

if (!app.requestSingleInstanceLock()) app.quit();

/** Panel and dashboard load the daemon's web client, with the token in the fragment as `shepctl web` does. */
const pageUrl = (path, query = "") => `${cfg.origin}/${path}${query}#token=${cfg.token}`;

let panel;
let dashboard;
let tray;
let shownAt = 0;
let ackWaiter = null;

function createPanel() {
  panel = new BrowserWindow({
    type: "panel", // NSPanel: can take keys without activating the app, floats over full-screen apps
    width: 520,
    height: 420,
    show: false,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    hasShadow: true,
    skipTaskbar: true,
    alwaysOnTop: true,
    backgroundColor: "#00000000",
    webPreferences: { preload: join(here, "preload.cjs"), contextIsolation: true, sandbox: true, nodeIntegration: false },
  });
  panel.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  panel.setAlwaysOnTop(true, "floating");
  panel.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  panel.webContents.on("will-navigate", (e, url) => {
    if (!url.startsWith(cfg.origin)) e.preventDefault();
  });
  // like the Swift panel: losing key status dismisses it
  panel.on("blur", () => setTimeout(() => !panel.isFocused() && hidePanel(), 80));
  if (cfg.token) panel.loadURL(pageUrl("panel.html"));
  else panel.loadURL(`data:text/html,${encodeURIComponent("<body style='font:14px system-ui;padding:20px'>No token yet. Start the daemon (shepctl daemon).</body>")}`);
}

function showPanel() {
  const { workArea } = screen.getPrimaryDisplay(); // the display with the menu bar, like the Swift panel
  const [w, h] = panel.getSize();
  panel.setPosition(Math.round(workArea.x + (workArea.width - w) / 2), Math.round(workArea.y + workArea.height * 0.2));
  shownAt = performance.now();
  panel.show();
  panel.focus();
  panel.webContents.send("panel:show");
}

function hidePanel() {
  if (panel.isVisible()) panel.hide();
}

const togglePanel = () => (panel.isVisible() && panel.isFocused() ? hidePanel() : showPanel());

function openDashboard(sessionId) {
  hidePanel();
  if (!dashboard || dashboard.isDestroyed()) {
    dashboard = new BrowserWindow({
      width: 1280,
      height: 800,
      title: "Shepherd",
      webPreferences: { preload: join(here, "preload.cjs"), contextIsolation: true, sandbox: true },
    });
    dashboard.on("closed", () => app.dock?.hide());
    dashboard.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
    dashboard.loadURL(pageUrl("", sessionId ? `?select=${encodeURIComponent(sessionId)}` : ""));
  } else if (sessionId) {
    dashboard.webContents.send("dashboard:select", sessionId);
  }
  app.dock?.show();
  dashboard.show();
  app.focus({ steal: true });
}

// ---- menu bar -------------------------------------------------------------------------------

let currentSessions = new Map();

function updateTray(sessions, state) {
  currentSessions = sessions;
  if (!tray) return;
  const list = [...sessions.values()];
  const n = (k) => list.filter((s) => s.attention.kind === k).length;
  const blocked = n("blocked");
  const done = n("done");
  const title = state === "offline" || state === "no-token" ? "⚪︎" : blocked ? `🔴 ${blocked}` : done ? `🟢 ${done}` : list.some((s) => s.attention.kind === "working") ? "🔵" : "○";
  tray.setTitle(title);
  tray.setToolTip(`Shepherd: ${state === "connected" ? `${list.length} sessions` : state}`);
  log("tray", { title, state, sessions: list.length });
}

// ---- spike: read-only checks, no synthetic input -------------------------------------------

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function runSpike() {
  await sleep(1500); // let the preloaded panel finish loading
  const before = await frontmostApp();
  const report = { frontmostBefore: before, hotkey: { accelerator: HOTKEY, registered: globalShortcut.isRegistered(HOTKEY) } };
  report.props = { alwaysOnTop: panel.isAlwaysOnTop(), visibleOnAllWorkspaces: panel.isVisibleOnAllWorkspaces(), type: "panel" };

  const probe = async () => ({
    visible: panel.isVisible(),
    winFocused: panel.isFocused(),
    webFocused: panel.webContents.isFocused(),
    docHasFocus: await panel.webContents.executeJavaScript("document.hasFocus()"),
    activeElement: await panel.webContents.executeJavaScript("document.activeElement && document.activeElement.id"),
    frontmost: await frontmostApp(),
  });

  showPanel();
  await sleep(600);
  report.afterShow = await probe();
  hidePanel();
  await sleep(600);
  report.afterHide = { visible: panel.isVisible(), frontmost: await frontmostApp() };
  report.appActivatedByShow = report.afterShow.frontmost !== before;
  report.focusRestoredAfterHide = report.afterHide.frontmost === before;

  // latency: show() until the renderer has reset itself and focused its input (acked over IPC)
  const times = [];
  for (let i = 0; i < 25; i++) {
    const ack = new Promise((resolve) => (ackWaiter = resolve));
    showPanel();
    times.push(await Promise.race([ack, sleep(2000).then(() => -1)]));
    hidePanel();
    await sleep(120);
  }
  const ok = times.filter((t) => t >= 0).sort((a, b) => a - b);
  report.showToReadyMs = { n: ok.length, min: +ok[0]?.toFixed(1), p50: +ok[Math.floor(ok.length / 2)]?.toFixed(1), max: +ok.at(-1)?.toFixed(1) };

  const metrics = app.getAppMetrics();
  report.memoryMB = Math.round(metrics.reduce((sum, m) => sum + (m.memory?.workingSetSize ?? 0), 0) / 1024);
  report.processes = metrics.length;
  report.versions = { electron: process.versions.electron, node: process.versions.node, chrome: process.versions.chrome };
  console.log(`SPIKE report ${JSON.stringify(report, null, 2)}`);
  await spikeInteraction();
  app.quit();
}

/** Types into the panel with input events sent straight to its webContents (never to the OS). */
async function spikeInteraction() {
  const wc = () => panel.webContents;
  const key = (keyCode, char) => {
    wc().sendInputEvent({ type: "keyDown", keyCode });
    if (char) wc().sendInputEvent({ type: "char", keyCode: char });
    wc().sendInputEvent({ type: "keyUp", keyCode });
  };
  const rows = () => wc().executeJavaScript("[...document.querySelectorAll('#list li')].map(l => l.textContent)");
  const out = {};

  showPanel();
  await sleep(500);
  out.allSessions = await rows();
  for (const c of "usr") key(c, c);
  await sleep(300);
  out.afterTypingUsr = { query: await wc().executeJavaScript("document.getElementById('q').value"), rows: await rows() };
  key("Escape");
  await sleep(300);
  out.escapeHides = !panel.isVisible();

  showPanel();
  await sleep(500);
  out.queryClearedOnReshow = (await wc().executeJavaScript("document.getElementById('q').value")) === "";
  for (const c of "usr") key(c, c);
  await sleep(300);
  key("Return");
  await sleep(3500);
  out.enterOpenedDashboard = !!dashboard && !dashboard.isDestroyed() && dashboard.isVisible();
  out.panelHiddenAfterEnter = !panel.isVisible();
  if (out.enterOpenedDashboard) {
    out.dashboard = await dashboard.webContents.executeJavaScript(
      "({ title: document.getElementById('bar-title').textContent, note: document.getElementById('bar-note').textContent, screen: (document.querySelector('.xterm-rows')?.textContent ?? '').slice(0, 80) })",
    );
    out.frontmostAfterOpen = await frontmostApp();
    // a second pick while the dashboard is open switches it instead of opening another
    const other = [...currentSessions.values()].find((s) => s.cwd === "/tmp");
    if (other) {
      dashboard.webContents.send("dashboard:select", other.id);
      await sleep(1500);
      out.dashboardSwitched = await dashboard.webContents.executeJavaScript("document.getElementById('bar-note').textContent");
    }
    dashboard.close();
    await sleep(300);
  }
  console.log(`SPIKE interaction ${JSON.stringify(out, null, 2)}`);
}

// ---- lifecycle ------------------------------------------------------------------------------

app.whenReady().then(() => {
  app.dock?.hide(); // a menu-bar app: no dock icon until the dashboard opens
  createPanel();
  tray = new Tray(nativeImage.createEmpty());
  tray.setTitle("⚪︎");
  tray.on("click", () => togglePanel());
  watchSessions(cfg, updateTray);

  const ok = globalShortcut.register(HOTKEY, togglePanel);
  console.log(ok ? `hotkey ${HOTKEY} registered` : `could not register hotkey ${HOTKEY} (taken by another app?)`);

  ipcMain.on("panel:hide", hidePanel);
  ipcMain.on("panel:open-session", (_e, id) => openDashboard(id));
  ipcMain.on("panel:shown-ack", () => {
    if (ackWaiter) {
      ackWaiter(performance.now() - shownAt);
      ackWaiter = null;
    }
  });
  if (SPIKE) void runSpike();
});

app.on("window-all-closed", (e) => e.preventDefault()); // stay alive in the menu bar
app.on("will-quit", () => globalShortcut.unregisterAll());
