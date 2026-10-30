# Dashboard: the main app window

**Status (2026-10-20): built and installed.** Direction agreed 2026-10-12, hybrid architecture (Swift app, web UI in a
WKWebView, PTYs held outside the app) accepted 2026-10-13, then built in steps 2 to 6 below between 2026-10-16 and
2026-10-20. **The holder backend is now the default and is what the installed `/Applications/Shepherd.app` runs.** Ghostty
tabs remain available with `"backend": {"kind": "ghostty"}`, `--ghostty` or `SHEPHERD_BACKEND=ghostty`. The previous
app (0.8.2, Ghostty backend) is kept at `~/.shepherd/backups/Shepherd-0.8.2-ghostty.app`; to go back, quit Shepherd and
copy it over `/Applications/Shepherd.app`, or install an older release. Not yet used by hand in daily work: expect rough
edges in the dashboard window, the board and the trimmed panel (see each step's "not checked by hand" list). This restores
a goal that was dropped by accident during the pivot to Ghostty on 2026-10-11 (see [How this got lost](#how-this-got-lost)).

Shepherd gets a main window that is where you work with agents, with the modal panel kept as a small quick-look
launcher. The goal is to break free of the TUI and Herdr limits while keeping the full Claude Code experience in
every session, and to keep controlling sessions from the phone web app.

## The three surfaces

| Surface | Job | Shape |
|---|---|---|
| **Dashboard** (new, main window) | Where work happens | A sessions view in the style of herdr/cmux: session list plus the live terminals, grouped and prioritised by attention. |
| **Tasks board** (new, same window) | What's being worked on | A conventional kanban board: columns, cards, drag or keys to move. Cards link to their sessions and open them in the dashboard. |
| **Modal panel** (exists, native) | See at a glance, then go | Minimal. Summon with the hotkey, see what needs you, jump to it, dismiss. |

**The panel stays small.** It is already getting large (Switch, Tasks, Create, Ask, Review). New work goes into
the dashboard, not the panel. Over time the panel should shrink back to glance-and-go, and the Tasks tab built
on 2026-10-11 is a stopgap that the board replaces.

## Principles

- **Core requirements, in order:** a simple, nice UI; real Claude Code sessions in it; control from a mobile web
  app. Memory, hot reload and cross-platform are nice to have and must not drive decisions over those three.
- **Full Claude Code experience per session.** Each session is the real `claude` TUI in a real terminal, not a
  reimplementation or a harness around the Agent SDK.
- **UI that is easy to style and change.** This is why the leading option puts the dashboard and board in web
  tech. It was not weighed properly the first time (see the history below).
- **Sessions outlive the app.** Quitting, updating or crashing the UI must not kill running agents.
- **Everything is task-based; this is the main difference from cmux.** Every session belongs to a task, so the
  kanban board reflects the state of every session. Context, plan and log live with the task, which makes it easy to
  organise documentation and to pick a task back up from a closed session. Not directories or workspaces, not loose
  sessions. (`docs/task-board.md` has the task files, `crook` and session linking, unchanged.)
- **Simple, and only what is useful.** cmux is growing quickly and most of what it offers is not needed. Add a
  feature when it proves useful in daily use, not because another tool has it. See [Non-goals](#non-goals).
- **Attention state stays hook-driven.** Unchanged.
- **Keyboard first.** App shortcuts use Cmd; Alt+letter and Ctrl-B belong to the terminal and Claude.

## What everything-is-a-task means

- **A session is always attached to a task.** Starting work creates the task (an inbox card with the session already
  linked) or picks an existing one; there is no separate "loose session". This also resolves the earlier open item
  about promoting untracked sessions. A session the user starts by hand in some other terminal still shows up, as
  an untracked card, until promoted.
- **The board is the index of all sessions.** Each card's column comes from its status plus the live state of its
  sessions (Needs you, In progress, Review, and so on, per `docs/task-board.md`). The sessions view is the same data
  seen as terminals, ordered by attention.
- **Picking a task up again is the primary flow.** Open a card: if a session is live, go to it; if not, start one
  with `--resume` and the plan and log injected. Agents keep the objective, plan and log current through `crook`.

## Non-goals

Things cmux and others do that this is deliberately not doing, unless daily use proves a need: workspace and
directory-centric grouping, a built-in browser, agent hibernation and cloud VMs, teams or accounts, multi-agent
support beyond Claude (OpenCode only if wanted later), a settings sprawl, and tracking another tool's roadmap.

## Architecture (leading option: hybrid)

```
 Shepherd.app (Swift, menu bar, native panel)
   ├─ WKWebView window: dashboard + kanban board (HTML/CSS/JS, xterm.js)
   ├─ HTTP + WebSocket server on loopback (the existing ShepherdWebKit server, extended)
   │      └─ also reached by the phone through `tailscale serve` behind the identity gate
   └─ holder links ──► one small holder process per session (owns the PTY, ring buffer, redraw on attach)
                          └─ `sh -c 'claude …'` (login-shell wrapper)
 registry file: session → claude session id, cwd, task, for `claude --resume` after a holder crash or reboot
```

- **Holders are the Herdr model.** Herdr has a headless server that owns the PTYs and a `session.json` that stores
  each pane's Claude session id; clients attach and detach, and a cold restart re-launches agents. Shepherd does the
  same with one small holder per session (dtach-shaped), so a crash of one holder cannot affect another and a holder
  exits by itself when its session ends. The app is a stateless client that finds holders by their sockets.
- **The WebSocket is part of the existing web server,** which already has the Host/Origin/Sec-Fetch-Site/identity
  checks. See spike C1 for the shape of the integration and the attack tests it survived.
- **Protocol:** one WebSocket per attached session; binary frames carry terminal bytes both ways; JSON text frames
  carry control (`list`, `spawn`, `attach`, `detach`, `resize`) and server events (`hello`, `attached`, `ready`,
  `size`, `reset`, `detached`, `error`). The token travels as a subprotocol, never in the URL.
- **PTY size policy:** whoever typed or resized last drives the PTY size; a passive client's resize is held until it
  types; every client resizes to the PTY size so all show the same screen. Smallest-wins was rejected because a
  phone would cramp the Mac window.
- **Slow clients are resynced, not buffered:** the bridge stops output, closes its holder link, and re-attaches
  (replay plus redraw) once the socket drains; a client stalled for 15 s is dropped. The holder must also drop a
  stalled link instead of blocking (spike A's holder froze).

### Reused from the current code

Hook-driven attention, task files and `crook`, the `SessionStart` context injection, `SHEPHERD_TASK_ID` /
`SHEPHERD_SESSION_ID` linking, task-linked `--session-id` / `--resume`, the phone view, keep-awake, the panel.
`SessionBackend` stays the seam: the holder-based backend sits next to `GhosttySessionBackend`; `HerdrSessionBackend`
is still slated for deletion. Answering prompts gets simpler with a real PTY, since letters and digits can be sent
directly, which Ghostty's AppleScript could not.

The parked TypeScript branches (`daemon-pty`, `attention-state`, `browser-terminal`, `electron-panel-spike`) remain
the spec for the terminal side. Port the ideas, not the code.

## Spike results (2026-10-12)

Throwaway code lives outside the repo (the Claude scratchpad of the session that ran them); the findings are what
matter. A, B, C1 and C2 were not tried against a real phone; C3 below was.

**A. A Swift holder can own PTYs for real `claude` sessions.**
- `openpty` + `posix_spawn` with `POSIX_SPAWN_SETSID`, opening the slave in a file action, gives a controlling TTY,
  resize (SIGWINCH) and Ctrl-C. No C target needed. If `claude` is the session leader it gets no controlling
  terminal and ignores resizes, so run it under a wrapper shell (`sh -c 'claude …; exit $?'`).
- Killing the client, even mid-turn, changes nothing; a reattach shows the result. Restarting the app is a non-event.
- A holder crash kills its session (SIGHUP when the master closes; tmux behaves the same). `claude --resume <id>`
  restores the conversation. Lost: a running tool call (Claude reports it as killed), a pending permission prompt
  (comes back as "interrupted"), and scrollback. A resumed session needs a fresh registry id.
- Raw replay garbles Claude's alternate-screen TUI when the ring is truncated or the client size differs. A forced
  redraw on attach (a resize nudge) repainted cleanly. A headless SwiftTerm `Terminal` can render a snapshot but has no
  colour serializer, so only build one if the redraw trick proves flaky.
- launchd is not needed for survival (a detached `SETSID` spawn reparents to PID 1). A LaunchAgent adds auto-restart.
  Either way, spawn through a login shell (`$SHELL -l -c`) or `PATH` lacks brew and fnm.

**B. xterm.js hosts the Claude TUI well (tested in Chrome, with the parked rig).**
- Works: typing, colours, resize, reattach after reload, the `@file` and `/` menus, bracketed paste, wheel scrolling,
  Option+Enter, Option+arrows, 645 KB of output in about 150 ms.
- xterm.js answers primary DA, focus events and bracketed paste; it does not answer the kitty keyboard protocol or
  XTVERSION queries, so Claude uses legacy key encoding.
- ZWJ emoji and flags render wrongly. ghostty-web (0.4.0) is usable but far less tested; keep it as an opt-in behind
  the same interface and default to xterm.js.
- Cmd combinations send nothing to the PTY, so app shortcuts can be Cmd-based without a prefix key. Avoid
  Alt+letter and Ctrl-B.

**C2. The same client works in a native WKWebView, with glue (about 350 lines of Swift plus page fixes).**
- Edit menu with `cut: copy: paste: selectAll: undo: redo:` and nil targets, or ⌘C and ⌘V do nothing.
- **Shift+Enter:** send `\x1b\r` on `keydown` and swallow both `keydown` and `keypress`. Swallowing only `keydown`
  sends a newline and then a submit.
- **Image paste:** on a paste with an image and no text, send Ctrl+V (`\x16`); Claude reads the macOS clipboard and
  shows `[Image #1]`. Only works when the session runs on the same Mac as the clipboard, so not from the phone.
- **Mouse selection:** Shift+drag does not select on macOS. Set `macOptionClickForcesSelection: true`; Option+drag
  selects and ⌘C copies. A plain drag goes to Claude as mouse reports.
- **Links:** xterm's default handler cannot work. Use `linkHandler` and `WebLinksAddon` posting to a
  `WKScriptMessageHandler`, plus the `confirm` UI-delegate method.
- **File drop:** the page only receives a name. Subclass `WKWebView`, override `performDragOperation`,
  `prepareForDragOperation`, `draggingEntered`, `draggingUpdated`, and type the shell-quoted path.
- Keystroke to echo median 3 ms; hide and re-show repaints in about 1 ms; session switch 5-11 ms.
- Memory (physical footprint, app plus WebKit helpers): 83 MB with one session; 85 MB after switching through three;
  231 MB with three extra xterm instances holding 5,000 coloured lines each (GPU about half). DOM renderer only; the
  WebGL renderer was not tried. Render only the selected terminal to avoid most of the growth.

**C1. The Swift WebSocket bridge works and held up under attack.**
- `NWProtocolWebSocket` makes a whole port WebSocket-only, so it cannot share a port with plain HTTP. A hand-rolled
  RFC 6455 upgrade inside a small HTTP server works: about 60 lines of frame parsing, 100 for handshake and messages,
  780 for the whole bridge, no dependencies (`Insecure.SHA1` from CryptoKit).
- 65 attack rows all refused with the process alive: bad Host, foreign or `null` Origin, cross-site fetch metadata,
  missing, wrong or query-string tokens, Funnel and forged identity headers, malformed HTTP (duplicate Host, CL+TE,
  `Content-Length: -1`), oversized headers, slowloris, 200 idle connections (cap 64), WebSocket framing violations
  (unmasked, RSV bits, bad opcodes, fragmented control frames), oversized frames without allocating, invalid UTF-8,
  message, ping and malformed-JSON floods, and spawns outside the directory allow-list.
- Bugs the spike found in its own code, worth testing for in the real one: a socket leak on every rejected request,
  an Origin check that compared only the host and not the port, and no ping rate limit. (The shipping phone server
  also compares only the host, but `Sec-Fetch-Site` rejects other localhost ports in browsers, so this is
  defence in depth, not an open hole.)
- Backpressure: capped, the bridge stayed at 15 MB through a 14 s unthrottled flood; uncapped it grew about 110 MB/s.
- Truncated replay loses terminal modes (bracketed paste, mouse tracking, focus events, alternate screen), so a
  reconnected multi-line paste would submit line by line. The holder now tracks `ESC[?…h/l` and re-emits the active
  modes ahead of the replay.
- Phone path: Tailscale Serve is a stock reverse proxy that strips client identity headers, sets its own, keeps Host
  and leaves Origin alone. A request shaped like Serve's passed the gate for the owner and was refused for other
  users, Funnel, untagged proxies, and a different Origin port or host.

**C3. A real phone terminal over Tailscale works, with a lot of touch glue (2026-10-15).** The C1 bridge served an
xterm.js page through a temporary `tailscale serve --https=8443` and an iPhone on the same tailnet drove real
`claude` sessions. The WebSocket upgrade through Serve and the identity gate worked first time. Code is on
`spike/hybrid-terminal` in `spikes/hybrid-terminal/c3-phone-test/`. What the first version got wrong, and what fixed it:

- Keyboard open left most of the screen to the header and menu. Fix: hide both while `visualViewport` is under 80% of
  the window height. Resizing the PTY on every keyboard toggle was not jumpy in use.
- An idle drop was silent (typing just did nothing). Fix: a red banner, a heartbeat (`list` every 8 s, 4 s deadline),
  automatic reconnect with backoff, and a wake on visibility, page show and online events. The banner shows and the
  reconnect is quick.
- Text was too small. Fix: 16 px by default, `A-`/`A+` buttons, remembered per phone.
- No scrollback by touch. xterm does not scroll its own buffer on a drag. Fullscreen Claude Code runs on the alternate
  screen with mouse tracking on, so a drag has to become SGR wheel events (`ESC[<64;1;1M` up, `ESC[<65;1;1M` down),
  with arrow keys for the alternate screen without mouse tracking and `scrollLines` otherwise. A gain of 2 and momentum
  on release feel right.
- Touch events stop arriving when the element they started on is removed, and xterm replaces its row elements as it
  redraws, so drags died after the first line. Fix: a transparent, stable overlay that owns all touches.
- That overlay must cancel the browser's follow-up click on every tap (`preventDefault` in `touchend`) and focus the
  input itself, otherwise the click blurs it and the keyboard flickers up and down. A long press worked because it
  produces no click. Block text selection and the long-press callout on the overlay.
- Key bar, in use order: `1 2 3 y n`, arrows, `Tab`, `Shift+Enter`, `Esc`, then the rest. With tap-to-type working,
  the return and keyboard buttons matter least.
- The `where-am-i` mod's truncated text cannot be expanded from the phone: a click on it hides the mod's panel, so
  forwarding a tap as a mouse click does not help and needs a change in the mod. Claude Code's own away summary was
  too long on mobile and was turned off globally with `awaySummaryEnabled: false`.

Still not known: how it feels over a long session, selecting and copying text on the phone (the overlay removes
long-press selection), image paste from the phone, and whether a purpose-built reply UI would beat a terminal for the
common case (answering a prompt).

## Prior art

- **cmux** (manaflow-ai/cmux, native Swift on libghostty): the reference for the sessions view. Vertical tabs,
  agent-attention notifications, socket API. Ruled out as a base by Adam on 2026-10-11 because it replaces
  Ghostty as the terminal, is huge and fast-moving (GPL app, BUSL server parts), is workspace/directory-centric
  with no task layer, and would fight shepherd over `~/.claude/settings.json`. Still the thing to compare the
  dashboard against.
- **Herdr**: the model for persistence (server owns PTYs, `session.json` stores each pane's Claude session id,
  clients attach). Its limits were no raw output stream, no control over layout, and a TUI that can't host a board.
- **tsk, Backlog.md, kanban-md**: kanban over markdown tasks. Reviewed in `docs/task-board.md`; none reused.
- **Embeddable native terminals:** SwiftTerm (mature, pure Swift, AppKit; its headless `Terminal` is useful for
  snapshots) and libghostty (what Ghostty and cmux use; third-party SPM wrapper `Lakr233/libghostty-spm`; API still
  moving). Neither has been used as the visible terminal in this repo.

## How this got lost

The TypeScript plan (2026-10-10) had this as Phase 7, "Live terminals + monitor-2 dashboard: live terminal tiles,
attention highlights, the board, approval cards", delivered as a web client in Electron. On 2026-10-11 the plan
changed to a Swift app with Ghostty as the terminal host, because Ghostty already renders terminals well and one
Swift process is cheaper than a Node daemon plus a web view. That change parked the web and Electron work and with
it the dashboard, but nothing recorded the dashboard as dropped, and `docs/HANDOFF.md` listed only the kanban
columns as "not built". Caught on 2026-10-12.

The first re-plan then recommended a native dashboard (SwiftTerm) and listed a web UI under "Rejected" on memory and
process-count grounds. Adam's actual criterion, how easy the UI is to style and change, was never weighed. The
earlier notes had in fact leaned toward a web dashboard in a WKWebView ("customisability comes from the UI being web
tech, not from Electron"). The spikes above were run to settle it.

## Rejected alternatives

- **Native SwiftUI/AppKit dashboard with SwiftTerm.** Smallest footprint, but a drag-and-drop board and a sessions
  view are much slower to build and restyle natively, and SwiftTerm has never been tried against Claude here. Not
  rejected on principle: if the web UI disappoints in daily use, the holder and protocol are unchanged and the view
  can be swapped.
- **Web dashboard over the parked Node daemon.** Works and was verified, but brings Node back as a second process
  and a second task and attention implementation to keep in step with the Swift ones. Kept as a fallback if the
  Swift holder proves painful; the protocol is designed so either can sit behind the web client.
- **Electron.** About 90 MB idle and 217 MB with the dashboard open (measured), against 21 MB for the Swift app. Its
  one real advantage, a non-activating panel, the Swift panel already has.
- **Ghostty tabs only, with a board plus peek view.** Cheapest, but terminals can't be embedded: Ghostty's
  AppleScript can't read the screen, place windows on a monitor or emit events. It stays as a backend, not the
  main surface.
- **Forking cmux.** See Prior art.
- **A TUI board in a terminal pane.** The original task-board design. Dropped with Herdr; a kanban board wants
  a real window.
- **Growing the modal panel into the main UI.** Rejected by Adam: it is already large and should be minimal.
- **`NWProtocolWebSocket` for the server.** It cannot share a port with HTTP (spike C1).
- **Smallest-wins PTY sizing.** A phone would shrink the Mac window.

## Open gaps

- **Is the hybrid final?** Accepted as the direction on 2026-10-13. Revisit only if a blocker turns up (the likeliest:
  the phone terminal path, or WKWebView glue that is more fragile than the spike suggests).
- **Sessions with no task.** Everything is task-based, but sessions can still start outside shepherd. Confirm they
  appear as untracked cards and how promotion works.
- **Phone terminals mostly work, with caveats.** Tested on an iPhone over Tailscale Serve on 2026-10-15 (C3 above).
  Open: copy and select on the phone, image paste, a long session, and whether answering prompts is better served by
  the existing purpose-built reply UI than by a terminal.
- **Not verified by hand:** real drag-and-drop (tested with a fake drag), real link hover and click (tested with DOM
  events), IME, `window.open` and `confirm` with no delegate, a global-hotkey summon over WKWebView (the app must be
  active first), Cmd+Tab and screenshot shortcuts.
- **Holder crash policy.** Detached holders survive the app; a crashed holder loses its session. Decide whether to
  auto-`--resume` registry sessions after a crash or reboot, and how a stale registry entry is cleared.
- **Holder supervision:** LaunchAgent with `KeepAlive` (auto-restart, survives logout) versus app-spawned detached
  processes (simpler to ship, keeps the app's identity). Leaning app-spawned first.
- **Production holder needs:** bounded writes (drop a stalled link), mode tracking, replay plus forced redraw, an
  allow-list of directories and agent kinds for spawn, the test-only `shell` kind behind a flag.
- **Untuned:** the 64-connection cap (all tailnet traffic appears as 127.0.0.1, so a per-address limit can't help),
  the 15 s stall limit, ring size. Kitty keyboard push/pop state is not tracked.
- **Memory with several live terminals** in one page (231 MB in the test). Render only the selected terminal; try
  the WebGL renderer.
- **Does Ghostty stay a first-class backend** or only a fallback? Decides how much two-backend upkeep is accepted.
- **Multi-monitor.** The two-monitor workflow is non-negotiable: panel on one screen, live sessions on the other. A
  native window can be placed explicitly; remember the position.
- **Attention without screen reading.** Hooks were enough under Ghostty; an embedded terminal can also read its own
  screen, which would close known gaps (a denied permission or Esc fires no hook; the folder-trust prompt has no
  hook).
- **Board behaviour.** Columns follow `docs/task-board.md` (Inbox, Ready, Needs you, In progress, Review, Done)
  unless Adam wants a typical Todo/Doing/Done set. Drag versus keys, how a task with several sessions is shown, PR
  badges and auto-Review, and the worktree-per-task option are undecided.
- **OpenCode** under the new backend. Claude only so far.
- **ZWJ emoji and flags** render wrongly in xterm.js. Cosmetic.

## Optional / nice to have

- Phone view mirrors the board.
- Tiled or split layouts showing several terminals at once.
- A Review view for PRs in the dashboard, so the panel's Review tab can shrink too.
- ghostty-web as an opt-in renderer; libghostty or SwiftTerm if a native view is ever wanted.
- Hot reload of the web UI in development.

## Suggested order

1. **Phone terminal check**, manually, with the spike bridge (small, answers the last unknown).
2. **Production holder** with the fixes above, plus the registry and `--resume` restore. **Built 2026-10-16, not yet
   committed:** `Sources/ShepherdHolder` (library), `Sources/shepherd-holder` (the holder process and a CLI to drive
   it), `Tests/ShepherdHolderTests` (29 tests, including real PTYs). Proven with a real Claude session: spawn, kill -9
   the holder, the session shows as interrupted, `restore` resumes it and the conversation is back. Decisions made
   while building it:
   - One holder per session, started with `shepherd-holder hold` by `HolderLauncher` (detached, own session, log per
     session). The daemon mode from the spike is gone.
   - **The holder socket has no `spawn` op.** The command arrives once, through the record and a spec file (env only,
     mode 0600, deleted after reading), so nothing that can reach the socket can start a process. The allow-list of
     directories and agent kinds therefore belongs to whatever accepts spawn requests from clients (the web bridge),
     not to the holder. The test-only `shell` agent is refused unless the launcher is created with `allowShell`.
   - The holder writes its own record (`~/.shepherd/sessions/<id>.json`) at start and at exit, so it is right when the
     app is not running. A record that says running with no answer on the socket is **interrupted**; nothing resumes
     it automatically. `restore` (and later a Resume button) does.
   - Replay plus a forced redraw: the holder replays its ring (512 KB) and reports the active terminal modes; the
     client re-asserts the modes and nudges the size (`Attachment.forceRedraw`).
   - Stalled clients are dropped (no progress for 300 ms), input to the PTY is bounded too, frames over 1 MB and
     unknown frame types drop the connection, at most 16 clients, idle unattached connections are dropped after 5 s.
   - Sockets live next to the records. A path over 103 bytes falls back to a locked `chdir`, which is process-wide,
     so keep the registry path short.
   - Not done yet: supervision beyond "the app spawns holders", the ring size and stall limits are untuned, Kitty
     keyboard state is not tracked, the web bridge is not ported (step 3).
3. **In-app backend** behind `SessionBackend`, with task-linked start and resume as the Ghostty backend does, and
   the bridge folded into `ShepherdWebKit`. **Backend built and pushed 2026-10-16. Bridge built the same day, see below.** `Sources/ShepherdHolderBackend/HolderSessionBackend.swift`, 12 tests that run real holders against a stand-in
   for `claude`. How it differs from the Ghostty backend:
   - The session list is the holder registry. A holder that answers is live; a record that says running with no answer
     is **interrupted** and shows as idle with "Interrupted. Resume to continue the conversation." and no prompt
     capability. `focus` on it resumes it with `claude --resume`; `close` dismisses it.
   - `prompt` and `respond` go straight into the PTY (bracketed paste when the app has turned it on, then Enter).
     `respond` reuses the Ghostty key vocabulary and the multi-select handling, translated to byte sequences.
   - A task's earlier conversation is resumed exactly as before; the task is linked before the agent starts and
     `SHEPHERD_TASK_ID`, `SHEPHERD_SESSION_ID` and `SHEPHERD_CROOK` are passed in the environment.
   - `backend.remoteControlNames: true` starts each session as `claude --remote-control "<task title>"`, so it appears
     under its task's name in the Claude mobile app (checked in the mods spike, Phase 0).
   - Claude runs under the user's login shell (`$SHELL -l -c`) with an absolute path to `claude`, because the app's own
     environment is nearly empty: a login shell gives `gh`, `node` and the rest of the Homebrew PATH but not
     `~/.local/bin`, which is why the path is absolute.
   - Turn it on with `"backend": {"kind": "holder"}` in the config, `SHEPHERD_BACKEND=holder` or `--holder`. Ghostty stays
     the default. `scripts/build-app.sh` now bundles `shepherd-holder` next to `crook`.
   - **Until the dashboard window exists, "go to a session" opens a Ghostty tab running
     `shepherd-holder attach <id>`** (Ctrl-\ detaches). That is the interim viewer.
   - Reuses `ghosttyAttention`, `GhosttyKeyMap`, `TranscriptPeek` and `ClaudeLocator` from `ShepherdGhostty`, so the new
     target depends on it. Move them to `ShepherdCore` if Ghostty stops being a backend.
   - A bug the backend tests found in the holder: while waiting for a session to exit the holder stopped reading its
     PTY, and a process that is closing its terminal waits for unread output to drain, so a kill right after start
     could leave both stuck (the child in state `E`, the holder blocked in `wait4`). The holder now drains output while
     it waits and every wait is bounded. Not reproduced in the in-process holder tests, only with real holder processes.
   **The bridge (built 2026-10-16, not yet committed):** `Sources/ShepherdTerminalBridge` ported from spike C1, hooked into
   the app's own HTTP server. The server's existing gate (Host, Sec-Fetch-Site, Origin host, Tailscale identity, owner
   only, no Funnel) runs first, then a `GET /ws` upgrade goes to `TerminalBridge.adopt`. 11 integration tests drive the
   real server, bridge and holders; 11 unit tests cover frames and the origin check. Proven end to end with a real
   Claude session started, typed into and read back over the WebSocket through the app's server and backend.
   - **Protocol** as in the spike, minus the bearer token: subprotocol `shepherd-v1`; `list` (the holder registry, with
     title, task, liveness, size), `spawn {cwd, cols, rows, task?, title?}`, `attach`, `detach`, `resize`; events
     `hello`, `sessions`, `spawned`, `attached`, `ready`, `size`, `reset`, `detached`, `error`. A holder id (not the
     Claude session id) names a session on the wire; `list` carries `claudeSessionID` and `taskID` to join it to the
     backend's sessions.
   - **No token.** Access is the server's gate, the same trust the existing API has (a local process can already read
     `~/.shepherd`). One addition for a socket that types into agents: `Origin` must match `Host` on port as well as host
     (the gate compares host only; another app on another localhost port is the same host), with the scheme's default
     port standing in when `Host` has none, as behind `tailscale serve`.
   - **Spawn allow-list is the existing one:** a session may start only in a folder the server offers at
     `/api/projects` (default directory plus git projects, exclusions applied). Only `claude` can be started; there is
     no `shell` kind on the wire.
   - Kept from the spike: PTY size follows whoever typed or resized last (a joiner sees the session's size and a
     passive client's resize is held until it types), output queues are bounded and a slow browser is resynced
     (`reset`, replay, redraw) rather than dropped, rate limits on input, control messages and pings, 64 connections,
     heartbeat pings, protocol violations close with a code.
   - `Public/terminal.html` is the phone test page (the fixed version from the C3 phone test) pointed at `/ws`, with a
     project picker fed by `/api/projects`. xterm.js 5.5.0 and the fit addon 0.10.0 are vendored in `Public/vendor/`.
   - The bridge lives in its own target in Swift 5 mode (shared state confined to one dispatch queue), like the holder.
   - `swift run ShepherdWeb --holder` runs the server with the holder backend for development; point `SHEPHERD_HOME`
     at a scratch folder and nothing of the real install is touched. The holder backend turns the bridge on in the app
     too (`backend.kind = "holder"`), reachable through Mobile Access like the rest of the web server.
   - Not done: the page is not linked from the existing phone view, the page has not been tried on the phone since the
     move, and the dashboard (step 4) will want its own page. A holder that is not in the registry, or an interrupted
     session, cannot be attached (the page lists live sessions only).

4. **Dashboard window.** **First version built 2026-10-16, not yet committed.** With the holder backend the window is
   where sessions are shown. A WKWebView around `Public/dashboard.html`, which the app's own web server serves; the page
   talks to the server like any browser (HTTP, the event stream and the `/ws` bridge). Checked by running the real app
   against a scratch registry with a snapshot of the window: two real Claude sessions listed, the real Claude UI in the
   terminal, "go to a session" from outside the page (`POST /api/sessions/<id>/focus`, which is what the panel, a
   notification and the Start button on a task do) selecting the right row and switching the terminal, closing a session
   removing it, and a session staying live after the app was stopped. Not checked by hand: typing, paste, drag-and-drop,
   the hotkey and the new-session sheet in the live window (the bridge side of each is tested).
   - **Page:** session list sorted by attention (needs you, finished, working, idle), a dot per state, the summary or
     the reason it is blocked under the title, ⌘1 to ⌘9 to jump, ⌘N for a new session (project picker fed by
     `/api/projects`, optional title), Close session, and for an interrupted session a placeholder with Resume. One
     terminal is rendered and re-attached as the selection changes (the memory gap noted below). The glue from spike C2
     is in: Shift+Enter sends ESC CR on keydown and swallows the keypress, an image paste with no text sends Ctrl+V,
     Option works as Meta and Option+drag selects, links open in the browser, dropped files type their quoted paths.
   - **Window:** `DashboardWindowController`, remembers its frame, hides with the hotkey (Hyper+D by default,
     `hotkey.dashboard`) and with ⌘W, "Open Dashboard" at the top of the status item's context menu. A minimal main menu
     (Quit, Close Window, Edit) is installed because an app with no menu bar gives ⌘C and ⌘V nothing to run. JS
     `confirm()` and `alert()` show real alerts. The WebKit delegate methods must be declared `@MainActor @Sendable` or
     Swift 6 treats them as a near miss and WebKit never calls them (confirm would silently return "no").
   - **Server:** `MobileAccessModel.ensureServer()` starts the web server for the dashboard whether or not Mobile Access is
     on; only turning Mobile Access on keeps the Mac awake or publishes it (and restarts a dashboard-started server with
     those options). `SHEPHERD_WEB_PORT` overrides the port, to run a second copy next to the installed app. New route:
     `POST /api/sessions/<id>/close`.
   - **Replaces** the interim "open a Ghostty tab attached to the holder" for going to a session.
   - Dev: `SHEPHERD_DASHBOARD_SNAPSHOT=<png>` writes a picture of the window after it loads and after each `show`, to look
     at the layout without screen-recording permission; `--show-dashboard` opens it at launch.
   - Not done: the task label is only the title (a task field and group headings come with the board), no answer buttons
     for a blocked session (the terminal is right there; the phone page is the place for buttons), no unseen-badge on the
     Dock or menu bar beyond what the panel already shows, `shepherd-holder attach` still exists for use from any terminal.
5. **Tasks board.** **First version built 2026-10-16, not yet committed.** A second view in the dashboard page (Sessions |
   Board tabs, ⌘B). Checked the same way as the window: the real app against a scratch registry and scratch task files,
   a snapshot of the board with tasks in every column, and the API driven with curl (start a task that has a live
   session returns that session; start a ready task creates one, links it and moves the task to In progress; a folder
   the server doesn't offer is refused). Not checked by hand: dragging a card, the keyboard, the drawer and the
   new-task box in the live window.
   - **Columns** as in `docs/task-board.md`: Inbox, Ready, Needs you, In progress, Review, Done (the 15 latest).
     An active task is in Needs you when any of its sessions is blocked, finished and unseen, or **interrupted** (not in
     the original table: an interrupted session needs you to resume it), otherwise In progress. A live session with no
     task shows as a dashed card in the same two columns with **Make a task**, which creates the task from the session's
     title and folder, links it and marks it active.
   - **Cards:** number and title, the objective (two lines), plan progress (a bar and n/m), the best state of the task's
     live sessions or "No live session", the folder, a PR badge when the task has one (set by hand or by a later PR
     step; nothing detects PRs yet).
   - **Moving:** drag between Inbox, Ready, In progress, Review and Done (Needs you is computed, so it takes no drops);
     `[` and `]` step a card back and forward; the drawer has a status menu. Moving a card to Done is allowed from the
     board because it is the user's call (agents still can't).
   - **Starting:** double-click, Enter, or the drawer's button (Start, Resume or Go to session). It goes to the task's live
     session if there is one, otherwise starts or resumes one in the task's folder (the default directory when the task
     has none) and moves an inbox or ready task to In progress, exactly what the panel's Tasks tab does.
   - **Drawer:** objective, the plan checklist, sessions with their state, folder and branch, and the log, newest first.
     Read-only: the agent keeps the plan and log current through `crook`.
   - **New task:** the box at the top, Enter to add to the Inbox, with a folder picker (the server's start targets).
   - **API** (`TasksAPI.swift`): `GET /api/tasks`, `GET /api/tasks/<id>`, `POST /api/tasks`, `POST /api/tasks/<id>/status`,
     `POST /api/tasks/<id>/start`, `POST /api/tasks/from-session`; sessions now carry `task_id`. The folder rule is the
     phone's: a task is created or started only in a folder offered at `/api/projects`.
   - **How it stays live:** the page re-reads tasks every 3 seconds while the board is showing and whenever a session
     event arrives. Nothing watches the task files, so an agent's `crook` update shows within 3 seconds, not instantly.
   - Not done: PR detection and the automatic move to Review when a PR is marked ready, worktree-per-task, several
     sessions on one task shown separately (the card shows the best state; the drawer lists them all), deleting a task,
     editing the objective or plan from the board, task groups in the Sessions list.
6. **Trim the panel** back to glance and go, once the board has replaced its Tasks tab. **Started 2026-10-19, not yet
   committed: the Tasks tab only.** With the holder backend the panel's Tasks tab is replaced by a "Board ↗" button that
   opens the dashboard on the board, and Tab skips it; with the Ghostty backend (no dashboard) the tab stays. Not checked
   by eye (the panel can't be driven without the hotkey), only built and the suite run. Left as it was, for you to decide:
   **Create** (also in the dashboard as ⌘N), **Ask** (inline `claude -p`), and **Review** (PRs; the plan lists a Review
   view in the dashboard as optional). Each is a feature in daily use, so none was removed unasked.

7. **Omnibar (decided 2026-10-20, first version built).** The launcher panel's job moves into a bar across the top of the
   dashboard, so one surface does everything and the whole flow works from the keyboard.
   - **Summoning:** the dashboard hotkey (`hotkey.dashboard`, default hyper+d), the Dock icon or the menu item bring the
     window up with the cursor in the bar. Pressing the hotkey while the dashboard is showing keeps the window and
     returns the cursor to the bar (it no longer hides it; ⌘W or the Dock closes it). ⌘K does the same from inside the
     page. Esc with an empty bar returns to the terminal.
   - **Modes** (chips on the bar; Tab and Shift+Tab cycle them, or start with a prefix; Backspace on an empty bar goes back
     to Switch): **Switch** (default) fuzzy-finds sessions, then tasks with no live session (Enter goes to the session, or
     starts or resumes the task's); **New** (`+`) lists the server's folders and Enter starts a session there; **Task**
     (`#`) takes a title, Enter adds it to the Inbox and ⌘Enter adds it and starts it. ⌘N keeps the modal sheet (folder
     and title) for starting a session.
   - **After Enter on a session or a new session**, focus goes straight into the terminal; the bar never takes focus back
     by itself (a session arriving or attaching used to be able to; `focusTerm` now refuses while the bar has focus).
   - **Ask and Review (built 2026-10-30, uncommitted; not tried by hand in the live window).** Two more modes, `?` and `!`
     as prefixes, Tab cycles to them. The app's `claude -p` runner, `gh` fetcher and PR worktrees reach the server as
     `OmnibarServices` closures (`ShepherdWebKit/OmnibarAPI.swift`); endpoints `POST /api/ask`, `POST /api/ask/continue`,
     `GET /api/reviews`, `POST /api/reviews/start|ignore|restore`. **Ask:** Enter asks (read-only, Haiku, as in the panel),
     the answer shows under the bar, a follow-up Enter continues the same inline conversation, Esc starts over, ⌘Enter
     carries it on in a real session in the default folder (`--resume`); a request that needs more than read-only starts a
     session itself. **Review:** the same three views as the panel (`@` yours, `%` ignored, otherwise waiting on you),
     Enter opens the PR on GitHub, ⌘Enter starts the review session (worktree, cloning first if needed) and goes to it,
     ⌘Backspace ignores or restores. **Still to do: remove the native panel** (and its hotkey, `onRunInlinePrompt` and the
     Review and Ask tabs) once these have been used for a while. Rejected: a separate Review view in the dashboard
     (the omnibar list is enough for a queue this size). Open: PR rows do not show whether a review session already
     exists, so starting twice makes two sessions.
   - **Was not in the first version:** **Ask** (a one-off `claude -p` answered inline, ⌘Enter to continue it as a session)
     and **Review** (the PR list, ignore and restore, start a review session). Both are native code today
     (`ClaudeCLIRunner`, `GitHubReviewFetcher`, `PRWorktree`), so each needs a server endpoint, passed in as a closure the
     way session spawning is. Until they exist the panel stays on its own hotkey (hyper+w) for exactly those two.
   - **Decision:** the panel is removed once Ask and Review work in the bar. Rejected: keeping it as an optional compact
     mode (two UIs to maintain for one job, and it cannot show a terminal); a hotkey that toggles the dashboard away
     (the point is summon-and-type; hiding has ⌘W); sending focus into the terminal on every summon (it makes the bar
     unreachable without the mouse).
   - **Open:** whether Switch should also search finished tasks, project names and PR titles; recent-first ordering for
     New (the panel ranks folders by use, the bar uses the server's order); a Task-mode folder picker (it uses the default
     folder today); whether ⌘K should also be reachable while the terminal has a program that wants ⌘K (none known).

8. **Task structure and finishing (designed 2026-10-22; built: Done, Reopen and the stored result; parent and subtasks; the Sessions record with cross-folder resume and a transcript view. Notes, handoff, workspace and Pick up built 2026-10-30; not built: ordered children, multi-repo spawning).** Tasks are of very different shapes, and
   everything so far is tuned for one-and-done ones. The shapes (from the user): a **quick question** whose answer is
   definitive and whose session is not needed again but must stay findable; a **long-lived topic** (the reseller
   investigation: many questions, MCP calls, scripts) that must be pickable up again with its findings, scripts and
   conversation; a **change across several repos** that needs coordinating; a **complex feature in one repo** broken into
   several tasks and PRs, worked **one after the other** (stacked PRs rejected: review changes make them too painful).
   - **One structure, not four types:** a task that can contain tasks. Every task starts as a leaf; "split into
     subtasks" turns it into a parent. The properties that differ (what it produces: an answer, a PR or an artefact; its
     folders; whether it is ordered) live on the task, nothing is classified up front. Quick question = a leaf. Topic =
     a parent that stays open with a child per question. Multi-repo = a parent with a child per repo. Sequential
     feature = a parent whose children are PR-sized and ordered.
   - **Finishing (built first, because it does not depend on the hierarchy).** One **Done** action, the same on every
     task, from the session header, `D` on the board, the drawer, and the omnibar. It (1) asks the task's live session to
     write a short result (`crook task result <id> <text>`, stored in a `## Result` section), waiting up to about a
     minute and falling back to the session's own summary line so Done can never hang; (2) ends the task's sessions
     (their conversations stay resumable in Claude's history); (3) sets the status to done. **Reopen** puts a done task
     back to active and shows Resume. Only the user can mark a task done; agents still cannot. The session header's
     "Close session" (which ended the session but left its task active) becomes Done plus a quieter "End session".
     On a **parent with open children**, Done asks and defaults to finishing all of them.
   - **Next, in order:** (2) parent link, a Subtasks list in the drawer, roll-up on the card, "new subtask here" in the
     omnibar; (3) a Notes section agents append to, a per-task **workspace folder** (`~/.shepherd/workspaces/<id>/`) for
     scripts that belong to no repo, and **Pick up**: resume the old conversation, or start a fresh session handed the
     notes and workspace (a very long conversation is often better replaced than resumed); (4) ordered children: only the
     next one is startable, a merged PR (already detected) offers "start the next", each child begins from fresh main;
     (5) multi-repo: a lead session *proposes* sessions in other folders, shown as "Needs you" on the board, and they start
     only when approved.
   - **Notes, handoff, workspace and Pick up (built 2026-10-30, uncommitted).** A task file gains `## Notes` (dated lines
     agents append with `crook task note <id> <text>`) and `## Handoff` (a short "where it stands", replaced whole with
     `crook task handoff <id> <text>`). `crook task workspace <id>` creates and prints `~/.shepherd/workspaces/<id>/`
     (beside the tasks folder, so `SHEPHERD_HOME` moves it). The SessionStart context now carries the workspace path, the
     handoff, and the newest notes (they get up to half the remaining room, ahead of the log), and tells the agent how to
     record them. **Pick up fresh** (`POST /api/tasks/<id>/pickup`, a drawer button shown when the task has past sessions
     and none running) starts a new session, not a resume, with a prompt to read the handoff, notes and workspace and
     report where things stand; `CreateSessionRequest.fresh` skips the usual resume of the task's last conversation. The
     existing Start/Resume and per-session Resume stay as the "resume the old conversation" half. The drawer shows
     Handoff, Notes and the workspace path. Not checked by hand in the live window. Not done: opening the workspace
     folder from the drawer, a size cap on notes beyond the context budget, an automatic handoff when the agent never
     writes one.
   - **Rejected:** a separate project/epic entity (one more concept; a task that grows into a parent is more natural);
     labels only (no roll-up of progress or state); a global parent session across tasks (it accumulates unrelated
     context; the task file is the durable state); agents splitting work and spawning sessions unasked (cost multiplies and
     nobody notices); worktrees and stacked PRs for the one-repo feature (sequential children make them unnecessary).
   - **Open:** how a long-lived topic is shown so it does not sit in the board's flow forever (an ongoing state, or its own
     view); whether a parent's status is derived from its children (leaning yes); real dependencies between children versus
     telling the agents; the Notes and handoff size (task context is capped near 9,000 characters, so parents need a
     maintained summary); what Done does to a task with an open PR (warn, do not block); searching done tasks from the omnibar.
   - **Optional:** an "End session only" shortcut; an automatic result when the agent does not answer; a Reference view
     of finished tasks.
