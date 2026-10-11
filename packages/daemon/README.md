# @shepherd/daemon

Owns the agent terminals, replacing Herdr. One long-lived process runs a `claude` per session in a
PTY (`node-pty`) and keeps a headless terminal (`@xterm/headless`) for each, so a client can attach
later with a screen snapshot, peek, or stream raw bytes.

    pnpm install                      # postinstall restores node-pty's spawn-helper exec bit
    node src/cli.ts daemon            # foreground; socket at ~/.shepherd/shepherd.sock (mode 0600)
    node src/cli.ts new --task 3      # start or resume task 3 (cwd = the task's project_path)
    node src/cli.ts new "fix the build"   # plain session in the current directory
    node src/cli.ts list | peek <id> | attach <id> | kill <id>   # ids can be prefixes; Ctrl-] detaches

## Task sessions

`session.create` with a `taskId`:
- resumes the task's newest linked conversation if its transcript exists, with `--resume <id>`;
- otherwise starts a new one with `--session-id <uuid>` (we choose the id) and links it to the
  task **before** the agent starts;
- sets `SHEPHERD_TASK_ID` and `SHEPHERD_SESSION_ID` in the agent's environment, which is what the
  `crook hook session-start` hook (see `../tasks`) uses to inject the plan and re-link after `/clear`.

## Protocol

NDJSON over the unix socket: `{id, method, params}` -> `{id, result}` or `{id, error}`; events are
`{event, ...}` lines. Methods: `ping`, `events.subscribe`, `session.list|create|attach|detach|input|
resize|peek|kill|remove`. `session.attach` returns `{snapshot}` (escape sequences that redraw the
screen) and then streams `session.data` events to that connection.

## Limits so far

- Agents are children of the daemon, so they die with it. The daemon must outlive the UI, but
  restarting it still ends sessions. Task links and transcripts survive, so `new --task N` resumes.
- No attention state yet (blocked/working/idle); that will come from Claude Code hooks.
- Session list is in memory only.
- Session-scoped `CLAUDE_*` variables are stripped from the agent environment. Starting the daemon
  inside a Claude Code session otherwise turns transcript saving off for everything it launches.
- Needs `claude` on the daemon's PATH.
