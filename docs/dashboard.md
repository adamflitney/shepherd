# Dashboard: the main app window

**Status: direction agreed 2026-10-12, nothing built yet.** This restores a goal that was dropped by accident
during the pivot to Ghostty on 2026-10-11 (see [How this got lost](#how-this-got-lost)).

Shepherd gets a native main window that is where you work with agents, with the modal panel kept as a small
quick-look launcher. The goal is to break free of the TUI and Herdr limits while keeping the full Claude Code
experience in every session.

## The three surfaces

| Surface | Job | Shape |
|---|---|---|
| **Dashboard** (new, main window) | Where work happens | A sessions view in the style of herdr/cmux: session list plus the live terminals, grouped and prioritised by attention. |
| **Tasks board** (new, same window) | What's being worked on | A conventional kanban board: columns, cards, drag or keys to move. Cards link to their sessions and open them in the dashboard. |
| **Modal panel** (exists) | See at a glance, then go | Minimal. Summon with the hotkey, see what needs you, jump to it, dismiss. |

**The panel stays small.** It is already getting large (Switch, Tasks, Create, Ask, Review). New work goes into
the dashboard, not the panel. Over time the panel should shrink back to glance-and-go, and the Tasks tab built
on 2026-10-11 is a stopgap that the board replaces.

## Principles

- **Full Claude Code experience per session.** Each session is the real `claude` TUI in a real terminal, not a
  reimplementation or a harness around the Agent SDK.
- **Native, one process.** The app is Swift and AppKit/SwiftUI. It idles at about 21 MB today and the dashboard
  shouldn't change that character.
- **Tasks are the main grouping**, not directories (see `docs/task-board.md` for the task files, `crook` and the
  session-linking rules, all unchanged).
- **Attention state stays hook-driven.** Unchanged.
- **Keyboard first.**

## How it fits with what exists

- **`SessionBackend` stays the seam.** The dashboard needs sessions it can embed, so a new in-app backend owns
  PTYs and renders them. `GhosttySessionBackend` stays as an alternative backend (terminals in Ghostty tabs);
  `HerdrSessionBackend` is still slated for deletion.
- **Reused as is:** hook-driven attention, task files and `crook`, the `SessionStart` context injection,
  `SHEPHERD_TASK_ID` / `SHEPHERD_SESSION_ID` linking, task-linked `--session-id` / `--resume`, the phone view,
  keep-awake.
- **The parked TypeScript branches are the spec for the terminal side:** `daemon-pty` (PTY ownership, headless
  screen state, snapshot on attach, resize), `browser-terminal` (the session list sorted by attention, new-session
  dialog) and `electron-panel-spike` (measurements). Port the ideas, not the code.

## Prior art

- **cmux** (manaflow-ai/cmux, native Swift on libghostty): the reference for the sessions view. Vertical tabs,
  agent-attention notifications, socket API. Ruled out as a base by Adam on 2026-10-11 because it replaces
  Ghostty as the terminal, is huge and fast-moving (GPL app, BUSL server parts), is workspace/directory-centric
  with no task layer, and would fight shepherd over `~/.claude/settings.json`. Still the thing to compare the
  dashboard against.
- **Herdr**: the sessions-list-plus-panes model this is escaping. Its limits were no raw output stream, no
  control over layout, and a TUI that can't host a board.
- **tsk, Backlog.md, kanban-md**: kanban over markdown tasks. Reviewed in `docs/task-board.md`; none reused.
- **Embeddable terminals:** SwiftTerm (mature, pure Swift, AppKit) and libghostty (what Ghostty and cmux use;
  third-party SPM wrapper `Lakr233/libghostty-spm`; API still moving). From the 2026-10-11 notes. Neither has been
  tried in this repo.

## How this got lost

The TypeScript plan (2026-10-10) had this as Phase 7, "Live terminals + monitor-2 dashboard: live terminal tiles,
attention highlights, the board, approval cards", delivered as a web client in Electron. On 2026-10-11 the plan
changed to a Swift app with Ghostty as the terminal host, because Ghostty already renders terminals well and one
Swift process is cheaper than a Node daemon plus a web view. That change parked the web and Electron work and with
it the dashboard, but nothing recorded the dashboard as dropped, and `docs/HANDOFF.md` listed only the kanban
columns as "not built". Caught on 2026-10-12.

## Rejected alternatives

- **Web dashboard in a WKWebView, backed by the parked TS daemon.** Works (xterm.js and ghostty-web both rendered
  in WKWebView), but costs about 135 MB with a live terminal and brings back Node as a second process with a
  second task and attention implementation to keep in step.
- **Electron.** About 90 MB idle and 217 MB with the dashboard open (measured), against 21 MB for the Swift app.
  Its one real advantage, a non-activating panel, the Swift panel already has.
- **Ghostty tabs only, with a board plus peek view.** Cheapest, but terminals can't be embedded: Ghostty's
  AppleScript can't read the screen, place windows on a monitor or emit events. It stays as a backend, not the
  main surface.
- **Forking cmux.** See Prior art.
- **A TUI board in a terminal pane.** The original task-board design. Dropped with Herdr; a kanban board wants
  a real window.
- **Growing the modal panel into the main UI.** Rejected by Adam: it is already large and should be minimal.

## Open gaps

- **What differs from cmux?** Adam said the dashboard has "a few opinionated differences" from cmux. Task-first
  grouping is the obvious one. The rest are not written down yet; ask before designing the sessions view.
- **Terminal view:** SwiftTerm or libghostty. Needs a spike: keyboard and IME fidelity, scrollback, selection,
  colours and Claude Code's own TUI (the question is whether it feels like Ghostty), plus footprint per session.
- **PTY lifetime.** Sessions owned by the app die when it quits. Task links and `--resume` make that cheap, but
  decide whether to accept it, add a small helper process, or auto-resume linked sessions at launch.
- **Does Ghostty stay a first-class backend** or only a fallback? This decides how much two-backend upkeep is
  accepted (peek from transcript vs. from the terminal, key handling, answering prompts).
- **Multi-monitor.** The two-monitor workflow is non-negotiable: panel on one screen, live sessions on the
  other. A native window can be placed explicitly, which Ghostty couldn't. Remember the position.
- **Attention without screen reading.** Hooks were enough under Ghostty; an embedded terminal can also read its
  own screen, which would close known gaps (a denied permission or Esc fires no hook; the folder-trust prompt
  has no hook).
- **Board behaviour.** Columns follow `docs/task-board.md` (Inbox, Ready, Needs you, In progress, Review, Done)
  unless Adam wants a typical Todo/Doing/Done set. Drag-and-drop versus keys, how a task with several sessions
  is shown, PR badges and auto-Review, and the worktree-per-task option are all undecided.
- **OpenCode** under the embedded backend. Claude only so far.

## Optional / nice to have

- Phone view mirrors the board.
- Tiled or split layouts showing several terminals at once.
- A Review view for PRs in the dashboard, so the panel's Review tab can shrink too.
- libghostty in place of SwiftTerm once its API settles.

## Suggested order

1. **Spike the terminal view** in a throwaway window: SwiftTerm hosting a real `claude`, judged against Ghostty on feel
   and memory. Decides the biggest open risk.
2. **In-app session backend** behind `SessionBackend`, with task-linked start and resume as the Ghostty backend does.
3. **Dashboard window**: sessions list plus embedded terminal, attention-sorted, with Enter to go and a hotkey to
   open it.
4. **Tasks board** in the same window.
5. **Trim the panel** back to glance and go, once the board has replaced its Tasks tab.
