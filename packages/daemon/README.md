# @shepherd/daemon

Owns the agent terminals, replacing Herdr. One long-lived process runs a `claude` per session in a
PTY (`node-pty`) and keeps a headless terminal (`@xterm/headless`) for each, so a client can attach
later with a screen snapshot, peek, or stream raw bytes.

    pnpm install                      # postinstall restores node-pty's spawn-helper exec bit
    node src/cli.ts daemon            # foreground; socket at ~/.shepherd/shepherd.sock (mode 0600)
    node src/cli.ts new --task 3      # start or resume task 3 (cwd = the task's project_path)
    node src/cli.ts new "fix the build"   # plain session in the current directory
    node src/cli.ts list | peek <id> | attach <id> | kill <id>   # ids can be prefixes; Ctrl-] detaches
    node src/cli.ts send <id> <text> | key <id> enter|esc|down|...   # drive a session without attaching

## Browser client

    pnpm --filter @shepherd/web build     # once; the daemon serves packages/web/dist if it exists
    node src/cli.ts daemon                # also listens on 127.0.0.1:7330 (SHEPHERD_WEB_PORT)
    node src/cli.ts web                   # prints the link; open it

The link carries a secret in the `#fragment` (`~/.shepherd/web-token`, mode 0600), which the page keeps in
localStorage and strips from the address bar. The browser speaks the same JSON protocol as the unix
socket over a WebSocket (`/ws?token=...`), so everything `shepctl` can do, a tab can do.

Because any web page can send requests to localhost, the WebSocket requires **all** of: an accepted `Host`
header (blocks DNS rebinding), an `Origin` matching that host (blocks cross-site hijacking), and the token.
Extra hostnames (e.g. a Tailscale name) go in `SHEPHERD_ALLOWED_HOSTS`. Static files are served with a
strict CSP, and session titles (which come from the terminal) are always rendered as text.

The terminal emulator is `xterm.js` by default. `?term=ghostty` switches to ghostty-web (libghostty-vt as
WASM; the choice is remembered). Both sit behind one small `TermView` interface in `packages/web/src/terminal.ts`.
Keys: Alt+Up/Down switch sessions, Alt+N starts one.

`SHEPHERD_AGENT_COMMAND=/bin/bash` makes the daemon run that instead of `claude`, for developing without spending tokens.

## Task sessions

`session.create` with a `taskId`:
- resumes the task's newest linked conversation if its transcript exists, with `--resume <id>`;
- otherwise starts a new one with `--session-id <uuid>` (we choose the id) and links it to the
  task **before** the agent starts;
- sets `SHEPHERD_TASK_ID` and `SHEPHERD_SESSION_ID` in the agent's environment, which is what the
  `crook hook session-start` hook (see `../tasks`) uses to inject the plan and re-link after `/clear`.

## Attention state

Each session has an `attention` (`blocked | done | working | idle | unknown`, plus `blocker`
`needsPermission | needsAnswer | failed`, `summary`, `options`, `progress`, `since`). It comes from Claude
Code hooks, ported from the Swift `shepherd_write_state.py`; with Herdr gone, hooks decide working and
idle too, not only the reason for being blocked.

    node src/cli.ts hooks install      # into ~/.claude/settings.json (original kept as .shepherd-backup)
    node src/cli.ts hooks status | uninstall     # both accept --file <settings.json>

- `UserPromptSubmit` -> working; `Stop` -> idle; `PermissionRequest` -> blocked (what is being
  approved); `AskUserQuestion`/`ExitPlanMode` -> blocked with the real question and options.
- `PostToolUse` clears a blocked state to working, because Claude Code has no "resolved" event.
- **done** means "finished while nobody was looking": a Stop (or clean exit) with no client attached.
  Attaching to the session or typing into it marks it seen, and it becomes idle.
- `unknown` until the first hook arrives, so a session with no hooks installed stays unknown.
- Hooks run `src/hook-cli.ts`, which forwards the payload to the daemon and never fails or blocks.
  After `/clear` Claude Code's session id changes; the daemon follows via `SHEPHERD_SESSION_ID`.
- Known gap: denying a permission prompt, or interrupting, fires no hook, so a blocked session stays
  blocked until the next prompt or Stop.

## Protocol

NDJSON over the unix socket: `{id, method, params}` -> `{id, result}` or `{id, error}`; events are
`{event, ...}` lines. Methods: `ping`, `events.subscribe`, `session.list|create|attach|detach|input|
resize|peek|kill|remove`, and `hook.event` (used by the hook script). `session.attach` returns `{snapshot}` (escape sequences that redraw the
screen) and then streams `session.data` events to that connection.

## Limits so far

- Agents are children of the daemon, so they die with it. The daemon must outlive the UI, but
  restarting it still ends sessions. Task links and transcripts survive, so `new --task N` resumes.
- Session list is in memory only.
- Session-scoped `CLAUDE_*` variables are stripped from the agent environment. Starting the daemon
  inside a Claude Code session otherwise turns transcript saving off for everything it launches.
- Needs `claude` on the daemon's PATH.
