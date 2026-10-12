# Shepherd: where things stand (handoff, 2026-10-12)

Read this first when picking the work up on another machine. Everything described here is on the
`swift-ghostty-host` branch of this repo (pushed to `origin`); `main` is untouched and nothing is merged.

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

Kanban columns as a view; PR badges and auto-move to Review; worktree-per-task; a task option in the
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
