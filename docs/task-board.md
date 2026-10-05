# Task board — design notes

**Status: design only, nothing built yet (2026-10-05).**

A kanban-style view of what every agent session is working on: which tasks are in progress, which are
waiting on you, which are ready for review. It must be self-contained. Someone who installs shepherd
should get task tracking and the board without Obsidian, Notion or any other tool. The board is a
terminal UI (TUI) that runs in a Herdr pane. The menu bar app stays a launcher and doesn't grow a
board UI of its own.

This is also the first step in folding [warden](https://github.com/adamflitney/warden)'s design into
shepherd rather than replacing shepherd with warden (see [Relationship to warden](#relationship-to-warden)).

## Goals

- See at a glance what every session is doing, grouped by state, on one board across all projects.
- Tasks outlive sessions. A task can be worked on by several sessions over days, and a session can end
  without losing the plan or log.
- Agents keep their own task up to date (status, plan, log) without the user doing bookkeeping.
- Sessions nobody has created a task for still show up, so the board is useful from the first launch.
- The board updates live: when a session blocks or finishes, its card moves without a refresh.

## Prior art

**The `agent-sessions` skill** (`~/.claude/skills/agent-sessions`, personal, not in this repo). This is
what the board replaces. Tasks are Obsidian notes in a global `Agent Tasks/` folder:
- **Frontmatter:** `status` (active | blocked | done), `sessions` (Claude session ids),
  `project_path`, `objective`, `created`, `updated`, `session_state` (working | idle),
  `progress_done` and `progress_total`.
- **Body:** a `## Plan` checklist and a dated `## Log`. Each note is meant to be self-sufficient, so a
  fresh session can resume the work from the Plan section alone.
- **Session mapping:** `~/.claude/session-tasks.json` maps session id → note paths.
- **Liveness hook:** `~/.claude/hooks/agent-sessions-liveness.sh` (on SessionStart, UserPromptSubmit
  and Stop) patches `updated` and `session_state` on every linked note.
- **The board:** an Obsidian Base with filter `status != done`.

It works, but it needs Obsidian, its REST plugin and an MCP server. Agents also spend tokens on
MCP calls just to keep frontmatter in sync, and its live state is a coarse working/idle copy of what
shepherd already knows precisely.

**[tsk](https://github.com/smarzban/tsk)** (Rust, Ratatui, MIT). A "Linear in the terminal" built
for Herdr, with a TUI board for humans and a CLI for agents.
- **Storage:** one JSON store, `~/.tsk/tsk.json`. Tasks are scoped to a repo path or a "desk"
  (outside any project).
- **Statuses:** fixed at open, ready, started, blocked, review, done. They're grouped as NEEDS YOU,
  IN MOTION and ON DECK.
- **Live reload:** the TUI watches the store's mtime and size, and merges when it saves.
- **Herdr integration:** ships a `herdr-plugin.toml` with a `[[panes]] placement = "split"` entry,
  plus an open-or-focus action.
- **What we take:** the plugin pattern, the NEEDS YOU / IN MOTION / ON DECK grouping, and short
  task numbers handed to agents.

**[Backlog.md](https://github.com/MrLesk/Backlog.md)** (TypeScript/Bun, MIT) and
**[kanban-md](https://github.com/antopolskiy/kanban-md)** (Go, Bubble Tea, MIT). Both store one
markdown file per task with YAML frontmatter, have configurable columns, and live-reload when files
change. They're the closest existing tools. See Rejected alternatives for why neither is reused.

**[Herdr plugins](https://herdr.dev/docs/plugins/).**
- **What a plugin can do:** a `herdr-plugin.toml` can declare `[[panes]]` (any command, placed as
  overlay, popup, split, tab or zoomed), `[[actions]]` bindable to keys, `[[startup]]` hooks and
  event handlers.
- **Context:** the plugin receives `HERDR_PLUGIN_CONTEXT_JSON` with the current workspace, pane and
  agent.
- **Limit:** plugin v1 has no non-terminal UI, which is fine for a TUI.

**Warden** (`~/Dev/warden/PLAN.md`, shelved 2026-10-01). A designed but unbuilt Go + Bubble Tea
replacement for Herdr and shepherd: a daemon over tmux, a modal TUI with a dashboard and a lazygit-style
triage mode, and a finer attention-state model. See below.

**Inside shepherd already:**
- `SessionBackend` / `BackendEventHub` provide live session state and events.
- `AttentionState` is the attention model, including `TaskProgress` built from TodoWrite by the hooks.
- `SessionID` derives from the Claude session UUID, so it's stable across Herdr restarts.
- The Review tab's `GitHubReviewFetcher` fetches PRs through `gh`.
- `createSession` takes an initial prompt.
- The small JSON stores (`IgnoredPRStore` and others) set the persistence pattern.

## How it fits together

```
 agents ──(shepherd task … CLI / skill)──┐
                                          ▼
                              ~/.shepherd/tasks/*.md      (durable: what the task is)
                                          ▲
 board TUI (Herdr pane) ──reads/writes────┘
        │
        └──(local socket)──► Shepherd.app ──► Herdr socket   (live: what sessions are doing)
                               │
                               └── hook state files, PR fetcher, push, phone view
```

The design rests on keeping two kinds of state apart:

- **Durable task state lives in markdown files.** Agents (through the CLI) and the TUI write them.
- **Live session state lives only inside shepherd**, which already tracks it, and is served over a
  local socket.

The TUI joins the two. This avoids having two programs write the same file for different reasons,
which was the main open problem when live state was going to be written into frontmatter.

### Task files

One file per task in `~/.shepherd/tasks/`, named `<id>-<slug>.md` (e.g. `0042-board-tui.md`). The
folder is global across projects, like the Obsidian folder and like tsk.

```markdown
---
id: 42
title: Board TUI
objective: Build the shepherd board as a Herdr pane
project_path: /Users/adam/Dev/shepherd
status: active          # inbox | ready | active | review | done
sessions: [8c1f…]       # linked Claude session ids; cleared when done
branch: board-tui       # optional; used to find the PR
pr: https://github.com/…/pull/12   # optional; set by shepherd once found
created: 2026-10-05T10:00:00
updated: 2026-10-05T11:20:00
---

## Plan
- [x] Task store and parser
- [ ] Socket API

## Log
- 2026-10-05 11:20: Parser round-trips unknown fields.
```

**Rules:**
- **Unknown fields and sections are kept as written.** The parser must round-trip anything it
  doesn't recognise. Every off-the-shelf tool failed on this, and it keeps the files open to hand
  edits and future fields.
- **Writes are atomic** (write a temp file, then rename). Each writer re-reads the file just before
  writing and changes only the fields it means to change.
- **No live fields.** `session_state`, `progress_*` and the liveness `updated` pings are gone.
  Progress for a running session comes from shepherd (TodoWrite). The Plan checklist is what the
  agent last wrote down.
- **Short numeric ids.** You can tell an agent "work on task 42".

### Board columns

The column a card sits in is worked out from the task's `status` plus the live state of its linked
sessions:

| Column | Shown when |
|---|---|
| Inbox | `status: inbox` |
| Ready | `status: ready` (nothing has started it yet) |
| Needs you | `status: active` and any linked session is blocked or failed, or finished and unseen |
| In progress | `status: active` and the above doesn't apply (working, idle, or no live session; a badge says which) |
| Review | `status: review` |
| Done | `status: done` (hidden by default, or shows only the last few) |

**Untracked sessions.** A live session with no task appears as an untracked card in Needs you or In
progress. One key promotes it to a task: shepherd creates the file with the session's title, project
and id already filled in.

### Local socket API (in the app)

The phone view's HTTP server sits behind the Tailscale identity check, and a local TUI shouldn't go
through it. So the app opens a second listener:
- **Where:** `~/.shepherd/shepherd.sock`, mode 0600. The file permissions are the authentication.
- **Protocol:** NDJSON, like Herdr's socket, so `NDJSONFramer` can be reused.

Roughly the same surface as the phone API:

- `sessions.list`, plus an `events.subscribe` stream (backed by `BackendEventHub`).
- `session.focus`, `session.peek`, `session.respond`, `session.prompt`.
- `task.start <id>`: create a Herdr session in the task's project, with a prompt built from the
  objective and plan and the task already linked.
- `tasks.changed` events: the app watches the tasks folder (`DispatchSource`) so the TUI, the phone
  view and anything else can refresh.

This also answers warden's last open design question (how clients talk to the daemon). The
transport is a Unix socket, and the app is the daemon.

### Board TUI

- **What it is:** a Swift executable in this package, sharing a `ShepherdTasks` library (task model,
  frontmatter round-trip parser, store) with the app and the CLI.
- **Terminal handling:** written by hand, with no dependencies: raw mode, alternate screen, ANSI
  drawing, resize handling.
- **How it's launched:** a bundled Herdr plugin (`herdr-plugin.toml`) with a split or tab pane and an
  open-or-focus action bound to a key. Running it directly in any terminal works too.
- **Keys:** keyboard-first and lazygit-style, with a hint bar showing the actions for the selected
  card:
  - Move between columns and cards.
  - Enter: focus the card's session (through the socket).
  - `s`: start a Ready task.
  - `p`: peek at the session.
  - Answer a blocked session inline.
  - Move a card's status.
  - `n`: create a task.
  - Promote an untracked card.
- **Drawing the board on narrow panes:** columns side by side when the pane is wide, stacked groups
  (NEEDS YOU / IN MOTION / ON DECK) when it's narrow.
- **When shepherd isn't running:** the board still shows tasks from the files, with a "shepherd not
  running, live state unavailable" banner and no untracked cards.

### Agent interface: CLI and skill

The same executable as the board, with subcommands:

```
<cli> board                       # the TUI
<cli> task new "title" [--project .] [--objective …] [--status ready]
<cli> task list [--project .] [--status …] [--json]
<cli> task show 42
<cli> task link 42 [--session <id>]   # attach this session
<cli> task plan 42 < plan.md          # replace the Plan section
<cli> task log 42 "message"
<cli> task status 42 review
```

- **The bundled skill** replaces `agent-sessions`. It tells agents when to create, link, log and
  move tasks, and it uses the CLI rather than MCP calls.
- **Installing it:** next to the hooks from the existing "Install Hooks…" menu item, which already
  edits `~/.claude/settings.json` through `HookSettings`.
- **Which CLI is used** (shepherd's or the agent's own) is an open question, below.

### Migration from Obsidian

A one-off `<cli> task import <dir>` reads the `Agent Tasks/` notes:
- `active` → `active`.
- `blocked` → `active`. `blocked` was being used for "paused" as well as "stuck", so the import keeps
  the note's log and puts it in In progress.
- `done` → `done`.
- Sessions, objective, project path, plan and log carry over. The `session_state` and `progress_*`
  fields are dropped.

Once the import is done, retire the liveness hook, `~/.claude/session-tasks.json`, the Obsidian Base
and the `agent-sessions` skill. Remember to update the routing note in the global CLAUDE.md as well.

## Relationship to warden

Shepherd already has warden's main architecture under different names. Warden's daemon owns state
and serves thin clients. In shepherd, the app process owns state behind `SessionBackend` and serves
the panel and the phone view. Since shepherd ships and has users, and warden is unbuilt, warden's
ideas move into shepherd rather than the other way round.

| Warden idea | What happens to it |
|---|---|
| Daemon owns state, clients render it | **Adopted.** The app is the daemon, and the local socket is its client API. |
| Modal TUI (dashboard and triage mode, lazygit-style keys) | **Adopted gradually.** The board TUI is the first part, and triage mode is the obvious next view in the same binary. |
| Finer attention states (permission, question, **failed**, **compacting**) | **Adopt.** Shepherd already splits blocked into needs-answer and needs-permission. Add `failed` (StopFailure) and `compacting` (PreCompact/PostCompact) in `shepherd_write_state.py` and `AttentionState`. |
| Own daemon over tmux (replacing Herdr), reboot resume through tmux-resurrect | **Deferred.** Later this becomes a `TmuxSessionBackend` next to `HerdrSessionBackend`, behind the existing protocol, so Herdr users aren't forced over. Revisit once the TUI covers what Herdr's own UI is used for. |
| Go + Bubble Tea | **Not adopted.** It made sense for a separate product. Inside shepherd it would mean a second toolchain and a second task parser that could drift from the Swift one. |
| No menu bar app; Raycast as the summon surface | **Not adopted.** The app stays as a launcher (and hosts the phone view), and the global hotkey already covers summoning. |
| Meta-session and batch fan-out from Linear | **Later.** Easier with a task store: fan-out becomes "create N tasks, start them". |

## Delivery phases

1. **Task store, CLI and skill.** `ShepherdTasks` library (round-trip parser, atomic store) and the CLI
   `task` subcommands. Then the skill and the Obsidian import. Useful on its own: agents track tasks
   without Obsidian.
2. **Local socket API in the app,** with folder watching and `tasks.changed` events.
3. **Board TUI and Herdr plugin:** columns, untracked cards, focus, peek, moving status.
4. **Start from the board, and PR detection** (task branch to open PR, shown on the card).
5. **The warden changes:** the failed and compacting states, then triage mode in the TUI.

## Decisions, and what was rejected

- **Markdown files rather than a single tasks.json or SQLite.** A JSON store fits the existing pattern
  but is opaque to agents and to people editing by hand. SQLite would be a new kind of dependency for
  a dependency-free app, and is more than this scale needs. Markdown also makes the Obsidian import a
  near-copy.
- **Live state served by shepherd, not written into frontmatter.** Writing it into the files (the
  liveness-hook model) means two writers on every file, write races, and diffs churning every few
  seconds. The TUI needs shepherd for untracked cards anyway.
- **A TUI rather than a board in the native panel or a new native window.** The user wants the app to
  stay a launcher and doesn't want more UI in it. The panel is too narrow for columns, and a native
  window plus a web board would be two implementations to keep in step.
- **The web view as the main board was rejected** for the same reason: the user prefers a terminal
  surface. The phone view may still get a simple task list later (see Optional).
- **Reusing tsk was rejected.** It stores tasks in one JSON file, its statuses are fixed, it has no
  custom fields, and adding live state would mean a fork that drifts.
- **Reusing Backlog.md was rejected.** It writes only a fixed set of fields, so it would delete
  shepherd's. Its task folder must live inside one project, and file names must follow its
  `back-N - Title.md` pattern.
- **Reusing or forking kanban-md was rejected.** It's the best fork candidate, but it drops unknown
  fields on write (a typed Go struct) and is Go.
- **taskell** (archived; the whole board in one file) and **kanban-tui** (SQLite) were rejected.
- **Go + Bubble Tea or Rust + Ratatui for the TUI was rejected.** Each offers a richer widget library
  but needs a second toolchain in the build and release scripts and a second task parser. A
  fixed-layout board is small enough to write against the raw terminal.
- **Swift TUI libraries were rejected.** TermKit (last pushed 2026-02) would be a dependency, and
  SwiftTUI hasn't been updated since 2024.
- **The phone HTTP API as the TUI's transport was rejected.** It sits behind the Tailscale identity
  check by design, so a local socket protected by file permissions is simpler and doesn't weaken
  that check.

## Open questions

- **CLI name.** The app's executable is `Shepherd`, and macOS file systems are usually
  case-insensitive, so a `shepherd` binary in the same build folder or `bin` path would clash. Options
  are `shep`, `shepherdctl`, or making the app executable dispatch subcommands itself. How it gets
  onto `PATH` also needs deciding: a symlink created by an "Install command-line tool…" menu item?
- **Linking sessions to tasks.**
  - **From the board:** when a session is started with `task.start`, shepherd knows the new session's
    id once Herdr reports it.
  - **When an agent links itself** with `task link`, the CLI needs the current Claude session id. The
    skill can pass it from context, which is what `agent-sessions` does today. Is there an environment
    variable or hook-provided value that's more reliable?
  - **Herdr environment variables:** could `agent.start` set a variable like `SHEPHERD_TASK=42` in the
    pane?
- **When cards move to Review.** Should an open PR on the task's branch move the card there
  automatically, or only show a badge and leave the move to the agent or user? Leaning towards a
  badge only, so the board never moves a card behind your back.
- **How a task with several sessions shows.** When one session is working and another blocked, the
  card goes to Needs you (the worst state wins, the same rule as the menu bar icon). Does the card
  need to show each session?
- **The phone view and tasks.** Does the phone view get a task list, or stay session-only?
- **Where `done` tasks go.** They could stay in the folder forever, or move to `tasks/archive/`
  after N days.
- **Cleaning up dead links.** Should the app tidy session ids for sessions that have closed, or leave
  the history and only treat live ones as linked?
- **OpenCode agents.** The hooks and skill are Claude Code-specific. With `agent.kind = opencode`,
  tasks would need linking by hand.
- **Keys.** The exact key map, and whether it should follow warden's verb/target leader-key grammar.

## Optional / nice to have

None of this is needed for the board to be useful.

- A compact Tasks tab in the panel, listing Needs you tasks for the hotkey flow. Only if it adds
  little to the panel.
- A task list on the phone, with Start and status changes.
- Phone and Mac notifications when a task (rather than a session) moves to Review.
- Per-project board filtering (`board --project .`).
- Pasting a Linear issue URL into "new task" to fill in the title and objective.
- Batch-starting several Ready tasks (warden's fan-out journey).
