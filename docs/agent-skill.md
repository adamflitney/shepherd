# Making sessions aware of Shepherd (exploration, 2026-10-30)

**Status (2026-10-30): built, installed, uncommitted. `session prompt` and `wait` not yet tried against a live second session.** Explored first; the build follows the proposal below with the deviations listed under "As built". The question: Herdr ships a skill that lets agents inspect and drive other panes.
Can Shepherd give its sessions the same, so an agent can search sessions and tasks, update tasks, and send messages to
other sessions?

**Answer: yes, and most of the plumbing exists.** The missing piece is a client for the web server's API that an agent
can run from its shell, plus the text that tells it when to. The proposal is to grow `crook` into that client and have it
print its own skill, the way `herdr --skill` does.

## As built

- `crook sessions`, `session read|prompt|wait`, `tasks search` and `crook --skill` (`Sources/crook/main.swift`; the decisions and the
  skill text are in `ShepherdTasks/AgentCLI.swift`, tested). The SessionStart context carries one pointer line to
  `crook --skill`. Sessions get `SHEPHERD_WEB_PORT` in their environment; `crook` falls back to `web.port` in
  `~/.config/shepherd/config.json`, then 8787, so sessions started before this still work after they restart `crook`.
- **Deviations from the proposal.** `tasks search` reads the task files itself (same matching as the server's search), so it
  works with the app closed. `prompt` is allowed to any live session, not only the same task family: that is what was asked
  for, and the safety rules (refuse self, refuse blocked, refuse sessions that cannot take input, mark the sender, log the
  message on the target task) stand in for the restriction. Narrowing it later is a one-line change in `promptRefusal`.
  `prompt --wait` waits up to 8 seconds for the target to start working, then until it settles (default 120 s; exit 2 on
  timeout).

## Prior art

- **Herdr's skill.** `herdr --skill` prints a `SKILL.md` from the binary itself, so the text always matches the installed
  version. `herdr --help` ends with a hint for AI readers ("SKIP if a Herdr skill is already in your context, otherwise
  run `herdr --skill`"). The skill is mostly a manual for the CLI: refuse unless `HERDR_ENV=1`, learn commands from
  `--help`, identify yourself through injected ids (`HERDR_PANE_ID`), then `herdr agent list | read | prompt --wait |
  wait --until blocked | send-keys`. Rules worth copying: only act when the user asks for it (the description says "use
  only when the user explicitly mentions Herdr"), do not answer another agent's blocked prompt without asking the user,
  read IDs from JSON rather than guessing, and wait on lifecycle state (`idle | working | blocked | done | unknown`).
- **`herdr-launch`** (`~/.claude/skills/herdr-launch`, personal): one task, spin up a workspace with an agent and a
  prompt. Shows the pattern of a thin skill over a CLI.
- **`agent-sessions`** (`~/.claude/skills/agent-sessions`): the Obsidian-based predecessor of the task files; agents
  paid MCP calls to keep frontmatter in sync. Shepherd's `crook` replaced it for tasks (`docs/task-board.md`).
- **What Shepherd agents already get.** The `SessionStart` hook injects the task's header, handoff, plan, notes and log
  and tells the agent how to use `crook task …` (`taskContext`). Environment: `SHEPHERD_SESSION_ID`, `SHEPHERD_TASK_ID`,
  `SHEPHERD_CROOK`. That covers "my own task". Nothing covers "other sessions" or "other tasks".
- **Mods spike** (`docs/mods-spike.md`): a Claude Code mod could surface Shepherd state inside Claude's UI. Different
  goal (showing, not letting the agent act); left alone.

## Findings

- **The server already has the verbs.** `SessionsAPI`: `GET /api/sessions`, `POST /api/sessions/<id>/prompt | respond |
  focus | close`, `GET .../peek` (the transcript tail). `TasksAPI`: list, detail, create, status, start, edit, done,
  reopen, resume, transcript, and (new today) `GET /api/tasks/search?q=`. Review and Ask are in `OmnibarAPI`.
- **A non-browser client passes the gate.** `requestSafety` needs a loopback `Host`, rejects cross-site fetch metadata
  and a foreign `Origin`, and wants `application/json` on a body. A plain HTTP client sending none of the browser headers
  is accepted, so `crook` needs no token. (A local process can already read `~/.shepherd`, so this is the same trust the
  rest of the API assumes.)
- **The port is the one gap.** The server listens on `web.port` (8787) or `SHEPHERD_WEB_PORT`. Passing
  `SHEPHERD_WEB_PORT` into every session's environment at spawn (next to `SHEPHERD_CROOK`) means `crook` never has to read
  config and a dev copy of the app talks to itself.
- **Identity is solved.** `SHEPHERD_SESSION_ID` and `SHEPHERD_TASK_ID` say who the caller is, so "my task" can be the
  default and `crook` can refuse to prompt itself.
- **Reading another session is cheap.** `peek` returns the transcript tail without a terminal, which is the equivalent
  of `herdr agent read`.
- **Waiting needs one new thing.** Herdr's `agent wait` blocks until a state. Shepherd has the event stream
  (`/api/events`, SSE); `crook` can poll `GET /api/sessions` every second or two, which is enough and needs no server
  change.

## Proposal

1. **`crook` becomes the agent's whole interface.** Existing `crook task …` stays. Add, all calling the local server and
   all printing JSON with `--json` or readable text otherwise:
   - `crook sessions [--task N] [--state blocked|working|idle|done]`: id, title, task, folder, state, summary.
   - `crook session read <id> [--lines N]`: the transcript tail (`peek`).
   - `crook session prompt <id> <text> [--wait]`: send a message; with `--wait`, poll until the session settles and print
     its new summary. Refuses the caller's own session and a session that is blocked on a prompt (as Herdr does).
   - `crook session wait <id> [--until blocked|idle|done] [--timeout s]`.
   - `crook tasks search <words>` (the new search endpoint), `crook task show <id>` (exists), `crook task list` (exists).
   - `crook session start --task N` / `crook task start N`: open a session on a task (uses `start`, so it resumes).
2. **`crook --skill` prints the skill, as `herdr --skill` does**, versioned with the binary. Content: when to use it
   (only on request or when the task needs another session's findings), the commands above, the rules from Herdr's skill,
   and Shepherd's own: record findings with `task note` and `task handoff`, never mark a task done, never answer another
   session's permission prompt.
3. **Delivery: one line in the SessionStart context**, not an installed skill file: "Other Shepherd sessions and tasks
   can be searched and messaged with `crook`; run `crook --skill` before you do." It costs a sentence per session and the
   full text is read only when needed. Sessions that are not Shepherd's never see it.
4. **Environment:** pass `SHEPHERD_WEB_PORT` (and nothing secret) at spawn.
5. **Safety:** `prompt` and `respond` are the sharp edges. A session that reads another session's output can be steered by
   text in it, and a prompt sent to a session that is mid-permission-prompt could be taken as an answer. So: refuse blocked
   targets, mark every message with its sender ("From session #12 / task #34:"), and show it in the target's task log so
   the user can see agents talking.

## Rejected alternatives

- **An MCP server.** Always-loaded tool definitions cost tokens in every session, it is another process to supervise, and
  the `agent-sessions` skill showed agents spending calls on bookkeeping. A CLI is paid for only when used, and Herdr's
  own design is CLI-first.
- **An installed `~/.claude/skills/shepherd/SKILL.md`.** Drifts from the binary and needs the hook installer to keep it
  current; also lists commands in every session's skill menu. `crook --skill` has neither problem.
- **Agents reading `~/.shepherd` directly.** Fine for tasks (they are files), but gives no live state and no way to send
  anything.
- **Talking to the holder sockets.** They are per-session and unauthenticated by design (the app is the only client);
  opening them to agents widens what can write to a PTY.
- **Herdr's socket API.** Gone with the Ghostty and holder backends; `HerdrSessionBackend` is slated for deletion.

## Open gaps

- **Does the user want agents to message each other at all, or only read?** Read and search carry little risk; `prompt`
  is the part to decide on. A middle path: `prompt` is allowed only to sessions on the same task or its parent and
  children, anything else asks the user (a "Needs you" card).
- **Reply path.** Herdr's `prompt --wait` returns when the target settles; the sender then `read`s the answer. Whether
  Shepherd also wants an inbox per task (messages as notes) is undecided.
- **Server not running.** The server starts with the app, but a session can outlive it; `crook` should say so plainly
  and fall back to task-file commands, which work without the app.
- **Cost of a polling wait.** One list call per second per waiter is fine for a few agents; an SSE reader would scale
  better and is a small addition if it matters.
- **Naming.** Herdr gives agents names; Shepherd sessions have ids and task numbers. Task numbers ("#34") may be the
  friendlier handle for the agent and the user.
- **Cross-folder tasks.** `crook task start` obeys the server's folder rule (only folders it offers); an agent asking for
  a session elsewhere is refused the same way.

## Optional

- `crook session new "<prompt>" --folder …`, a one-shot like `herdr-launch`.
- `crook notify` to push a phone notification (already a line in the task context today).
- Surfacing agent-to-agent messages on the board card.
- A read-only mode (`SHEPHERD_AGENT_API=read`) for sessions you do not want sending anything.

## Suggested order

1. `SHEPHERD_WEB_PORT` in the spawn environment, and a small HTTP client inside `crook`.
2. Read-only commands: `sessions`, `session read`, `tasks search`.
3. `crook --skill` and the context line.
4. `session prompt` and `wait`, with the safety rules above, once the read side has been used.
