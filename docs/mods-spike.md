# Shepherd as a mod: spike and first slice

**Status: proposal, 2026-10-14. Nothing built.** Comes out of a thought exercise on how much of shepherd a Claude Code
mod could take over (conclusions in the memory note `project_shepherd_mods_exploration`; a mocked storyboard is at
https://claude.ai/artifact/NCHMRCJo1LmqSxzJPcUFtU). This doc is the cheapest way to find out whether that picture holds.

## Hypothesis

A mod loaded into every Claude Code session can own the things that live inside a session: task context, state
reporting, answering blocked prompts, the task UI. The native app then shrinks to the menu-bar glance, the Hyper+W panel
and opening terminals, and Claude's own mobile app replaces the Tailscale web app. Adam's framing: lean on mods to do
more of the work so we build less outside them, not to replace everything.

## What the spike has to answer

Ordered by what would sink the idea.

| # | Question | If the answer is no |
|---|---|---|
| Q1 | Is the Claude mobile app enough? Remote Control on for Yoto's org, auto-connect and push for ordinary sessions, and a mod slash command or tool giving a useful text reply on the phone. The docs say a mod's drawing (band, panes, buttons) appears only in the terminal under Remote Control, so the phone is chat plus text | Keep the Tailscale web app, fed by the mod's state instead of hooks. A custom mobile client stays |
| Q2 | Can a session be answered from outside? A `tool.check` hook (allowed under the guard) can hold a permission prompt. How long may it wait, what do the terminal and the phone show while it holds, and does holding hide the phone's native prompt and push | Keep typing answers into the terminal, and let the phone answer natively without holding |
| Q3 | Can a mod do the plumbing? Read a task id from the environment, call `crook` through `$.process.run`, attach the task to the first prompt (`prompt.submit` context), register tools, deny `task_close`, report state to the app | Find which part fails; the hook-and-skill setup stays for that part |

One constraint found while checking the types: `session.end` has a **1.5 second** budget for all hooks. A Haiku-written
handoff at session end will not fit, so the handoff has to be written as the session goes (on `turn.complete`), not when
it closes. This also covers a tab closed with ⌘W or a crash.

## Plan

**Phase 0: phone checks (about 2 hours, no code).** The six-step list in the storyboard's "Test the phone first": org
setting, auto-connect and push with three real sessions renamed to their tasks, `claude --bg` visibility, `claude
remote-control --spawn worktree`. Record each as works / works with a catch / fails.

**Phase 1: probe mod (about 1 day, throwaway).** One mod, around 150 lines, `shepherd-probe`, loaded with `--plugin-dir`.
Each piece exists to answer one question and is deleted afterwards:

- a band, a button, a Markdown pane and `/probe`, opened from the terminal; and `/probe` typed from the phone, to see
  whether a text reply comes back (Q1)
- a `tool.check` hook that, when the engine would ask, polls a file for a decision, answered by `echo allow > …` from
  another terminal; try 5 s, 60 s and 10 min waits, and watch what the phone shows meanwhile (Q2)
- detectors for the two hooks the guard probably skips (`prompt.compose`, `classic.PermissionRequest`): a log line if
  either runs after all
- `$.session.send` to a second session, and the same session id arriving at the app (Q2)
- on `session.start`: read `SHEPHERD_TASK`, run `crook task show`; attach the result to the first prompt as `context`,
  register a `probe_log` tool that runs `crook task log` (Q3)
- a `tool.call` deny on a tool named `task_close` (Q3)
- on `session.end`: try a `$.model.complete` and see whether it finishes inside 1.5 s (Q3)

**Phase 2: first slice (2 to 3 days): a task-aware session.** The smallest mod worth keeping, additive to what exists:

1. **Briefing:** objective, plan and the last handoff attached to the session's first prompt from the task file. Not the
   system prompt (the guard blocks that), so it has to be re-attached after `/clear` and compaction.
2. **Tools:** `task_log`, `task_plan_set`, `task_status`, thin wrappers over `crook`. `task_close` is denied, so only the
   user closes a task.
3. **Band:** task title and plan progress above the prompt.
4. **State report:** on `turn.complete` and on a permission request, send the app the same state the shell hooks send
   today, so the app can ignore the shell hooks for sessions that have the mod.
5. **Rolling handoff:** after each turn, append the session's "where am I" line to the task log. Read it from
   `where-am-i`'s state (any plugin may read another's `$.state`) instead of making a second model call.
6. **Answer from the panel,** if Phase 1 says holding in `tool.check` works. Holding hides the native prompt from the
   phone until it resolves, so either the panel answers (and the phone loses the prompt) or the phone answers natively
   and the panel keeps typing keystrokes. Decide from what the probe shows.

The shell hooks and `crook` skill stay installed during the slice, so uninstalling the mod puts shepherd back exactly
as it is. Run it on one real task for a working day.

## Success criteria

1. Start a task from the panel and the new session knows its objective, plan and last handoff with nothing typed.
2. The agent updates the plan and log through tools, the task file shows it, and the agent cannot close the task.
3. A permission prompt is answered from the panel with the hold in place, and another from the phone natively, and the
   session continues within about 5 seconds each time.
4. After a tab is closed with ⌘W, the task log holds a handoff and the next session starts from it.
5. No extra model calls beyond where-am-i's, and usage-meter shows no visible change.
6. With the mod uninstalled, nothing about shepherd's current behaviour has changed.

## Decision gate

| Result | Next |
|---|---|
| All of Q1 to Q3 work | Build the Tasks sidebar pane, then delete the shell hooks and the web app |
| Q1 fails | Mod still pays off inside a session; keep a custom mobile client fed from the mod |
| Q2 fails | Mod handles briefing, tools and reporting; answering stays with the app |
| Q3 fails in part | Keep that part in the app and hooks, move the rest |

## Rejected alternatives

- **Build the dashboard window first.** The largest piece, and the most visible, but it depends on the same unproven
  plumbing. It would be built on guesses about what the mod can report.
- **Start with the Tasks sidebar or the board.** The nicest to look at, but least risky: it is only a pane. The unknowns
  are the phone and the plumbing.
- **Decide from the docs alone.** The docs settled Remote Control's basics but not whether a mod's UI draws on mobile,
  or how long a hook can wait. Both need an experiment.
- **Use `claude --bg` and Agent View as the host.** Reported not to appear in Remote Control (claudeissues #70546, closed
  "not planned"), and it knows nothing about tasks.
- **Install corgi.** It overlaps heavily with shepherd and would bring its own daemon and task model. Better read than adopted.
- **Handoff on session end with a model call.** The 1.5 s budget rules it out.
- **Make the mod one of Yoto's own (managed settings, marketplace folder via device management).** The only way to get
  `prompt.compose` and `classic.PermissionRequest` back, but not available to Adam right now.
- **Run on a personal API key or without managed settings.** Would skip the guard, but sidesteps Yoto's policy.

## Prior art

- **corgi / corgi-band** (github.com/Andriiklymiuk/corgi): settings hooks report each session to a daemon, which writes
  `sessions.json`; a thin mod polls it every 20 s and shows waiting sessions with Focus buttons. The same shape as the
  proposed split. It also does tasks, PR bots, phone access and handoff, so it is the main thing to study.
- **petekp/inbox:** per-session ledger of questions and PRs; pushes a token onto the session's row in herdr's sidebar
  with `herdr pane report-metadata`. Its author runs herdr.
- **herdr-fleet** (abhibansal60/claude-mods): about 100 lines, a pane over `herdr agent list` with `herdr agent focus`.
- **clodfarm:** 121-line waker: a flag file, a 1 s timer and `$.prompt.submit` start a turn in an idle session.
- **threads:** answers other sessions with `$.session.send` and Claude Code's per-session files. No licence, so idea only.
- **where-am-i, usage-meter, glance** (hamzafer/claude-code-mods, MIT): where-am-i and usage-meter are already
  installed. Their source is the reference for bands, `$.model.complete`, and reading `$.session.usage()`.
- **Existing shepherd:** `crook`, the task files, the task-context hook and the hook-fed state in `docs/task-board.md`.

## Open gaps

- **Org-managed Claude Code skips two of the hooks (decided: work around it).** `claude plugin validate` warns that
  `prompt.compose` and `classic.PermissionRequest` "do not run in a plugin a person installs where an organization manages
  Claude Code". The docs (code.claude.com/docs/en/plugins/mods/admin) explain why: a built-in guard, `sec-default`, loads
  ahead of every installed mod when the machine has managed settings or the user is on a Team or Enterprise plan, and it
  stops a user's mod changing the system prompt or what managed hooks decide. Everything else is allowed, including
  `tool.check` approvals, prompt rewrites, panes, commands, `$.process`, `$.http` and `$.session.send`. Yoto's setup fits
  (`~/.claude/remote-settings.json` pins `model: opusplan`). **Chosen route:** use the allowed hooks (`tool.check` to
  answer, `prompt.submit` context to brief). Making the plugin an organization mod needs managed settings and a
  marketplace folder deployed to every Mac, and running without managed settings sidesteps Yoto's policy; neither is
  available, so they are rejected below. Also noted: `policy-limits.json` has `remote_control_at_startup: false`, so
  auto-connect is something to switch on.
- **A mod's drawing does not reach the phone.** The mods overview says that under Remote Control the hooks run on the Mac
  but what a mod draws appears in the terminal there. The phone is plain chat. A mod can still help through tool results
  and slash commands that reply with text (a `/tasks` list), but not buttons or a docked list. The storyboard's phone
  mockups showed mod UI on the phone and were wrong on this.
- **How state reaches the app.** The shell hooks' message format lives in the Swift code and is not described here. The
  mod could call `$.process.run` on a small CLI or write a file the app watches; pick after reading the current hook code.
- **Where `SHEPHERD_TASK` comes from.** The app sets it when it opens a tab. Starting `claude` by hand or in herdr has no
  such variable, so the mod needs a fallback such as `crook task find --session`.
- **Host: herdr or Ghostty tabs.** Not decided. The spike should run in whichever Adam uses day to day.
- **Does auto-connect interact with mods?** Unknown whether the mod's band and panes behave the same in a session that
  Remote Control is attached to.
- **Mods run with full user privileges** and the API changes between releases. Pin a Claude Code version while building.
- **Multiple sessions on one task** and a task with a session in another repo's worktree are not designed here.

## Optional / nice to have

Not part of the slice; each stands alone.

- Tasks sidebar docked in every session, a list like herdr's with numbers to jump (the storyboard's 09:02 scene).
- Board pane; PR review pane with drafted comments Adam approves.
- herdr sidebar token push (`herdr pane report-metadata`), copied from petekp/inbox.
- Install glance, replay-theater and md-preview alongside, for their own sake.
- Claude Desktop as a richer board using the `Client` element (untested).
