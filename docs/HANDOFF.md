# Shepherd: where things stand (handoff, 2026-10-12)

Read this first when picking the work up on another machine. Everything described here is on the
`swift-ghostty-host` branch of this repo (pushed to `origin`); `main` is untouched and nothing is merged.

## Update 2026-10-30: where things stand after the 2026-10-22 work

**Read this first; the 2026-10-20 and 2026-10-15 sections below are history.** Branch `swift-ghostty-host`, pushed, 35+
commits ahead of `main`, no PR. Work since 2026-10-20 (all in `docs/dashboard.md`, steps 7 and 8):

- **Omnibar** across the top of the dashboard (Switch, New, Task modes; the hotkey summons it). Ask and Review are not in
  it yet, so the native panel stays until they are, then it is removed.
- **Board:** keyboard navigation, task details, PR detection (safer), Dock icon and launch-time dashboard, every session
  gets a task, task edit and delete, single-start web server, auto-title from Claude's title, faster wheel scrolling.
- **Task structure:** Done and Reopen with a stored `## Result`; parent and child tasks (one level); a `## Sessions`
  record per task (id, folder, started, title) so a task can resume or show a transcript from another folder.
- **Notes, workspace and Pick up:** started 2026-10-30, see the dashboard doc, step 8, for what is built.
- **Not built:** ordered children, multi-repo spawning, Ask and Review in the omnibar, a warning when Done is pressed on a
  task with an open PR, omnibar search of finished tasks, a place for long-lived topics on the board, `/clear` leaves the
  old session id on the task, shell sessions may ignore Ctrl+C, freeze recorder still in the tree.
- **Not tried by hand:** the hotkey, dragging cards between columns, the Dock click. Mods spike phases 1 and 2 untouched.
- **Decide:** a draft PR for the branch (do not mark ready without asking) and a release.
- **Tests:** `swift test`; the one known failure needs Herdr's socket (see 2026-10-20).

## Update 2026-10-20: the hybrid is built and installed

**Read this first, then the 2026-10-15 section below for how it got here.** Steps 2 to 6 of `docs/dashboard.md` are built
(PTY holder, holder-backed `SessionBackend`, terminal WebSocket bridge, dashboard window, task board, panel's Tasks tab
replaced by a button to the board), the holder backend is the default, and `/Applications/Shepherd.app` is that build.
The old app is backed up at `~/.shepherd/backups/Shepherd-0.8.2-ghostty.app`. The phone test and the mods Phase 0 are
finished and recorded in `docs/dashboard.md` and `docs/mods-spike.md`. Everything is on `swift-ghostty-host`.

- **Not yet used by hand:** the dashboard window with a keyboard and mouse (typing, paste, drag-and-drop, the hotkey, the
  new-session sheet), dragging cards on the board, the board's keys, the drawer. The server side of each is tested.
- **Open decisions:** whether Create, Ask and Review stay in the panel; whether to turn on `backend.remoteControlNames`
  (the Claude mobile app showed sessions under their task names in the Phase 0 test); the mods spike's Phases 1 and 2
  (a Claude Code mod for briefing, tools and state) are unstarted.
- **Not built:** PR detection and the move to Review when a PR is marked ready, worktree per task, a file watcher so the
  board updates instantly (it re-reads every 3 seconds), deleting or editing tasks from the board.
- **Known quirks:** a test in `ShepherdHerdrTests` fails on any machine without Herdr's socket (it names one agent id
  from another machine); a dev copy of the app run with a config that has Mobile Access on will publish itself through
  Tailscale Serve (set `SHEPHERD_WEB_PORT` for a second copy and remove the entry with `tailscale serve --https=<port> off`).

### Where this stopped (2026-10-20), and how to pick it up

- **Git:** branch `swift-ghostty-host`, last pushed commit `f50fef0` (the panel's Board button). **Uncommitted, on disk
  only:** making the holder the default (`Config.swift`, `main.swift`, `ConfigTests.swift`, `README.md`) and the doc
  updates (`docs/dashboard.md`, this file). The installed app was built from that working tree. Commit and push them first.
- **Installed:** `/Applications/Shepherd.app` is the holder-default build; old app at
  `~/.shepherd/backups/Shepherd-0.8.2-ghostty.app`. Hooks were not reinstalled (the `crook` in `~/.shepherd/bin` is a
  hand-copied build of the same source; the old copy is `crook.bak-20261016` beside it).
- **Next:** Adam is about to use the dashboard, board and panel by hand and has "numerous issues with the GUI" to report.
  Start from what he reports. Likely places: `Sources/ShepherdWebKit/Public/dashboard.html` (all page behaviour),
  `Sources/Shepherd/DashboardWindow.swift` (window, menu, drops), `Sources/ShepherdUI/SessionsListView.swift` (panel).
- **Tests:** `swift test`, about a minute. Everything passes except
  `herdrBackendLiveReconciliationTrustsWorkingOverAStaleHookFile`, which needs Herdr and a hard-coded agent id.

**Dev workflow that worked (the scripts lived in a temp folder and are gone):**

- *Run a throwaway copy without touching the real install:*
  `SHEPHERD_HOME=/tmp/shd SHEPHERD_WEB_PORT=18911 SHEPHERD_DASHBOARD_HASH=board SHEPHERD_DASHBOARD_SNAPSHOT=/tmp/shd/snap.png
  .build/debug/Shepherd --holder --show-dashboard`. `SHEPHERD_HOME` moves the sessions registry and the task files; the
  snapshot is a PNG of the window (read it to look at the layout; it is rewritten after each show). **Always set
  `SHEPHERD_WEB_PORT`**, and remove any serve entry afterwards (`tailscale serve status`, then
  `tailscale serve --https=<port> off`), because the real config has Mobile Access on and the copy publishes itself.
- *Make fixtures:* `.build/debug/crook task new/status/plan/log ...` and `.build/debug/shepherd-holder spawn --claude
  --cwd <repo> [--task N] --registry /tmp/shd/sessions`. `crook` refuses `status N done` when `CLAUDE_CODE_SESSION_ID` is
  set (inside a Claude session); use `env -u CLAUDE_CODE_SESSION_ID` for fixtures.
- *Drive the server from outside:* `curl` against `/api/sessions`, `/api/tasks`, `/api/projects`, POSTs for `focus`,
  `close`, task `start` and `status`. For the WebSocket, a short node script with `ws@8.18.0` installed in a scratch
  folder (`NODE_PATH=<folder>/node_modules`), origin header `http://127.0.0.1:<port>`, subprotocol `shepherd-v1`.
- *Clean up after:* `shepherd-holder list --registry <dir>`, `kill <id>` for each live one, then delete the scratch folder
  by literal path (a delete whose target comes from a command's output is blocked by the safety check).
- *Gotchas:* running the installed binary with an argument it does not know (for example `--help`) starts a second full
  app instance; the WebKit delegate methods must be `@MainActor @Sendable` or WebKit never calls them; the holder must
  keep draining its PTY while waiting for a session to exit (a stuck exit otherwise wedges both); `swift build` finishes
  in seconds when nothing changed, so a fast "Build complete" is normal.

## Update 2026-10-15: direction, spikes, and what is in flight

**Read this section first.** The rest of the file describes the Ghostty-backend code as of 2026-10-12 and is still
accurate for that code. This section is the state of the planning and spikes since then.

### Where the plan stands

- **`docs/dashboard.md` is the main plan.** Adam accepted the **hybrid** on 2026-10-13: a Swift app with a WKWebView
  dashboard and kanban board (HTML, xterm.js), a web server with a hand-rolled WebSocket, and one small PTY-holder
  process per session so sessions outlive the app. Everything is task-based (every session belongs to a task; the
  board reflects every session), which is the main difference from cmux; keep it simple, add only what proves useful.
  Revisit if a blocker turns up.
- **`docs/mods-spike.md` is a second line of thinking from another session (2026-10-14/15), not discussed in the
  session that wrote this section.** It proposes finding out whether a Claude Code mod can do the in-session work
  (task briefing, state reporting, answering prompts, the task UI), with Claude's own mobile app replacing the Tailscale
  web app. Terminals would stay in Ghostty or herdr, and it lists "build the dashboard window first" as rejected. Its
  probe mod is in `spike/shepherd-probe/`. Context is in the memory note `project_shepherd_mods_exploration` and a
  storyboard artifact linked from the doc.
- **These two are not reconciled.** They disagree on embedded terminals and on the phone. A reasonable reading is that
  they are complementary (the mods spike is cheaper and tests whether in-session plumbing plus Claude mobile is enough;
  the dashboard is the plan if it is not, and is where the kanban board lives), but that is the previous session's
  reading, not a decision. **Ask Adam which goes first.**

### Spike results (2026-10-12/13), short version

Full detail, glue code and numbers are in `docs/dashboard.md` ("Spike results"). Code is on the branch
`spike/hybrid-terminal` (`spikes/hybrid-terminal/`, with a README).

- **A (PTY holder in Swift): works.** `openpty` + `posix_spawn` with `POSIX_SPAWN_SETSID`. App restarts do not touch
  sessions. A holder crash kills its session; `claude --resume` recovers the conversation but not an in-flight tool
  call or pending permission prompt. Run `claude` under a wrapper shell or it ignores resizes.
- **B (xterm.js hosts Claude well):** needs a Shift+Enter handler (send `\x1b\r`) and an image-paste handler (send
  Ctrl+V). Cmd combinations are free for app shortcuts.
- **C2 (WKWebView host): works with glue** (Edit menu, link handler, native drop handler, Option+drag to select).
- **C1 (Swift WebSocket bridge): works and survived 65 attack tests.** `NWProtocolWebSocket` cannot share a port with
  HTTP, so the upgrade is hand-rolled (about 780 lines for the whole bridge).

### The phone terminal test (C3): done and torn down

A terminal on a real iPhone through Tailscale Serve works. The first version was clunky; the fixes below were made and
re-tested on the phone over the afternoon of 2026-10-15. Full list with reasons in `docs/dashboard.md` (spike C3).

- **Works:** WebSocket upgrade through Serve and the identity gate, real Claude sessions, keyboard-up layout, visible
  disconnect banner with automatic reconnect, larger text with `A-`/`A+`, touch scrolling with momentum, tap-to-type,
  key bar ordered by use.
- **Not solved:** the `where-am-i` mod's truncated text cannot be expanded on the phone (a click hides its panel;
  needs a change in the mod). Not tried: selecting or copying text on the phone, image paste, a long session.
- **Tailscale** was stopped before the test and started with `tailscale up --accept-routes`; it was left running.
  `tailscale down` puts it back if wanted.
- **Side effects:** Claude's away summary was turned off globally (`awaySummaryEnabled: false` in
  `~/.claude/settings.json`, backup alongside it). The phone sessions left a transcript and a trust entry for the scratch
  folder in `~/.claude.json`.
- **Torn down 2026-10-15:** bridge, holder, the `:8443` Serve entry (the 443 entry to 8787 is untouched), and the
  scratchpad `phone-state/` (token, logs, QR image). The code is on `spike/hybrid-terminal` in
  `spikes/hybrid-terminal/c3-phone-test/`; the vendored xterm files and the token are not in the repo (see its README).

### Repo and machine state

- **Branch `swift-ghostty-host`** is the working branch and is pushed.
- **Branch `spike/hybrid-terminal`** holds all the spike code including the phone test (pushed).
- **Parked TypeScript branches** (`task-store-ts`, `daemon-pty`, `attention-state`, `browser-terminal`,
  `electron-panel-spike`): the executable spec for the terminal side. **`main`** is v0.8.2 with Herdr.
- **Local `main` has one unpushed commit** (`abf0c01`, a Review-tab filter) that Adam said to ignore, and **`stash@{0}`**
  holds an uncommitted Herdr `createSession` retry fix, superseded by the Ghostty direction. Neither is lost; neither
  matters unless the Herdr backend is kept.
- **Installed `/Applications/Shepherd.app`** is the `swift-ghostty-host` build (still labelled 0.8.2) with hooks
  installed, including the `crook` SessionStart hook. Backups: `~/.claude/settings.json.pre-ghostty-backup`.
- **Small repo changes made this session:** `crook task objective`, `crook task plan set`, a nudge in the task context
  for tasks with no objective or plan, and `crook` refusing `task status done` inside Claude Code (agents finish at
  `review`; only the user closes a task). All committed and pushed.

### Side effects of the spikes on Adam's machine (so nothing is a surprise)

- A spike fork overwrote the clipboard and briefly stole focus; the old clipboard contents are lost.
- `~/.claude.json` has trust entries for scratch directories; `~/.shepherd/events.jsonl` has lines from spike sessions.
- Obsidian's MCP server was disconnected at the end of the session, so the Obsidian notes (`2026-10-12 Shepherd START
  HERE` and the long plan note) were not updated with any of this. Update them through the `my-notes` skill, or rely on
  this file.

### Suggested next steps (not agreed)

1. Decide the order of the mods spike and the dashboard work (see "These two are not reconciled"). TUIOS (tuios.dev) was looked at on 2026-10-15 and skipped for now: a Go
   terminal multiplexer with a daemon, a socket API, Claude Code hooks and phone pairing; the open question was whether
   Claude Code runs with full fidelity inside its panes, which nobody has tried.
2. If the dashboard goes ahead: production holder, then the in-app backend, then the dashboard window and board
   (`docs/dashboard.md`, "Suggested order").
3. If the mods spike goes first: its Phase 0 phone checks need no code.

## What this is

Shepherd is a macOS menu-bar app (Swift) that runs AI coding agents (Claude Code) in ordinary
**Ghostty tabs**, tracks which of them need you, and groups sessions by **task** rather than by
directory. The goal that started this: Claude Code keys everything by working directory, so finding
"the session I was using for X" was a hunt. Now a task (a markdown file) links its sessions, and
starting a task starts or resumes the right conversation with the task's plan injected.

Original problem, in short: the native shepherd app and the Herdr TUI were two UIs that only shared
socket state. Herdr is gone from the design: Ghostty hosts the terminals, hooks report state.

## Where the code is

| Branch | What | Status |
|---|---|---|
| **`swift-ghostty-host`** | The real work: Swift app + Ghostty backend + tasks | **Use this** |
| `task-store-ts`, `daemon-pty`, `attention-state`, `browser-terminal`, `electron-panel-spike` | An earlier TypeScript/Electron direction (PTY daemon, web client, Electron panel) | **Parked.** Kept as the executable spec the Swift code was ported from; nothing needs it to run |
| `main` | Pre-existing shepherd (Herdr backend), v0.8.2 + design notes | Unchanged |

New Swift modules (all in `Package.swift`): `ShepherdTasks` (task files, store, SessionStart hook
logic), `crook` (the task CLI agents use), `ShepherdGhostty` (AppleScript driver, session records,
hook-driven attention, key mapping, transcript peek). Hook-state parsing moved into `ShepherdCore`.

## Getting going on a new machine

```bash
git clone git@github.com:adamflitney/shepherd.git && cd shepherd && git checkout swift-ghostty-host
swift build                       # needs Swift 6 (Command Line Tools are enough)
scripts/test.sh                   # 428 tests. Use this, not `swift test`: on a Command Line Tools-only
                                  # machine SwiftPM can't find Swift Testing; the script passes the paths
scripts/install.sh                # builds, signs (ad hoc) and installs /Applications/Shepherd.app, with crook inside
```

Then: open Shepherd -> right-click the menu bar icon -> **Install Hooks…** (this edits
`~/.claude/settings.json` and is what makes attention state work; without it every session says
"unknown"), and optionally **Use Front Ghostty Window for Agents**. Needs **Ghostty 1.3+** and Claude Code
(`claude`, found in PATH, `~/.local/bin`, `~/.claude/local`, or Homebrew). Hotkey: Hyper+W.

Opt-in live tests (they drive the real Ghostty, opening windows they create themselves, and clean up):

```bash
SHEPHERD_LIVE_GHOSTTY=1 scripts/test.sh --filter LiveGhosttyTests      # the AppleScript layer
SHEPHERD_LIVE_E2E=1     scripts/test.sh --filter LiveEndToEndTests     # Ghostty + Claude + hooks + crook, ~85 s, spends a few cents
```

## What works (verified)

- Starting a task session in Ghostty (0.3-0.5 s), linked to the task before the agent runs; resuming a
  task's newest conversation; `SHEPHERD_TASK_ID` / `SHEPHERD_SESSION_ID` in the agent's environment.
- The SessionStart hook injecting the task's plan and log (a real Claude answered with a codeword that
  only existed in the task objective).
- Attention from hooks: working / blocked (permission or question, with real text and options) /
  done (= finished while nobody looked) / idle; followed through `/clear`.
- Answering questions: single choice (digit = arrow-down x (n-1) + Enter), **multi-select** (Enter toggles,
  Submit row, review, confirm), and Claude's **folder-trust prompt** (detected as blocked after 8 s of
  silence on a session started with a first message). Prompting a session (text, then Enter separately).
- Peek from the transcript; closing a session (ends the process, then the tab).
- Panel **Tasks tab** (Enter start/resume or go to live session, Cmd+Enter new task from typed text,
  Cmd+⌫ (backspace) done). Release app idles at 21 MB / 0% CPU.

## NOT verified: please check these by hand

- The **Tasks tab's look** (nobody has seen it on screen; only its logic is tested).
- The real **Hyper+W panel** with the Ghostty backend, and **Install Hooks** end to end on your real settings.
- Behaviour with several Ghostty windows / monitors in daily use.

## Not built yet

**The dashboard is the big missing piece:** a native main window with embedded terminals for sessions plus a
kanban Tasks board, with the modal panel kept minimal. It was dropped by accident in the Ghostty pivot and
restored on 2026-10-12; see `docs/dashboard.md` (direction, rejected alternatives, open gaps, suggested order).
The Ghostty backend is the stepping stone, not the destination.

Also not built: kanban columns (now part of the dashboard); PR badges and auto-move to Review; worktree-per-task; a task option in the
Create tab; editing a task's project from the panel; OpenCode under Ghostty (Claude only); a mobile-page
check (peek/respond already work through the same protocol). **Herdr is not deleted** (still builds and
passes its tests behind `--herdr`); delete `ShepherdHerdr`, its tests, the Terminal/Agent submenus and
`AttentionSinceStore` once the Ghostty backend has had real use.

## Things learned the hard way

- **Ghostty AppleScript** (1.3.1): `new window` / `new tab in <window>` with a surface configuration
  (`command`, `initial working directory`, `environment variables`); `input text` is "as if pasted";
  `send key` names are camelCase (`arrowDown escape enter tab space backspace delete home end pageUp
  pageDown`); **plain letters and digits sent with `send key` produce no text**; no screen reading and no
  events (but `perform action "write_screen_file:copy"` writes the screen to a file and puts its *path*
  on the clipboard, which clobbers the clipboard so shepherd doesn't use it); terminals still `exist` after
  their process ends; a window can't be placed on a monitor, hence the "agents window" convention.
- A Ghostty tab starts commands through a bare login shell, so use an **absolute path to `claude`** and to `crook`.
- Reading `ps` output only after the process exits **deadlocks** once it exceeds the pipe (~64 KB);
  drain pipes while the process runs (`ProcessRunner`). Unit tests with fakes missed this; the live test caught it.
- The Stop hook fires slightly **before** Claude writes the last reply to the transcript; peek waits briefly.
- Claude Code treats text and Enter arriving in one chunk as a paste, so send them separately.
- A daemon or test started inside a Claude Code session inherits `CLAUDE_CODE_*` variables that switch
  transcript saving off (relevant only to the parked TS daemon).
- `swift build` incremental builds sometimes leave stale test objects after a signature change (link errors):
  `touch Tests/*/*.swift` and rebuild.

## Safety notes

- I (Claude) once left hooks in `~/.claude/settings.json` pointing into a checkout that no longer had those
  files; I removed exactly those entries (backup: `~/.claude/settings.json.before-ts-hook-removal`). Hook
  installs always keep a `.shepherd-backup` next to settings.json.
- Live tests trust a scratch directory in Claude's one-time trust prompt (an entry in `~/.claude.json`
  remains per run) and never touch your own windows or sessions.

## Longer record

The full chronological log, decisions and measurements (memory of Electron vs Swift vs WKWebView, why cmux
was ruled out, the research behind each choice) is in the Obsidian note
`2026-10-10 2357 Shepherd — task-centric sessions and platform plan.md` (and the short
`2026-10-12 Shepherd START HERE` note there points back to this file).
