# @shepherd/tasks

Task store and `crook` CLI for shepherd. Tasks are markdown files in `~/.shepherd/tasks/`
(`$SHEPHERD_HOME/tasks` if set); see `docs/task-board.md` for the design.

Runs on Node 23.6+ with native type stripping, so there is no build step:

    pnpm install
    node src/cli.ts task list
    pnpm test

Put it on your PATH with `ln -s "$PWD/src/cli.ts" ~/.local/bin/crook`.

## SessionStart hook

Injects the task's plan and recent log into any session linked to a task. Add to
`~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [{ "type": "command", "command": "crook hook session-start" }]
      }
    ]
  }
}
```

A session is linked when it was linked earlier (`crook task link`), or when shepherd started it
with `SHEPHERD_TASK_ID=<id>` in its environment. The env var also re-links after `/clear`, where
the session id changes. Sessions without a task are left alone, and the hook never fails the session.

## Agent instructions

Add this to CLAUDE.md or a skill so agents keep the task current:

> When you are working on a shepherd task (the session start context says "You are working on
> shepherd task #N"), keep it current with the `crook` CLI, not by editing the file by hand:
> `crook task plan N add "<step>"` for new steps, `crook task plan N check <n>` when one is done,
> `crook task log N "<what happened, decisions, where you stopped>"` before you finish, and
> `crook task status N review` when the work is ready for review. Write the log so a fresh
> session could resume from the plan and log alone. If you are asked to "continue task N" and the
> session is not linked, run `crook task link N` first, then `crook task show N`.
