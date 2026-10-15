# shepherd-probe

Throwaway mod for Phase 1 of `docs/mods-spike.md`. It answers questions; it is not the product. Delete it afterwards.
Every finding is appended to `~/.shepherd-probe/log.jsonl`, so the result of a check is `cat` away.

Written for an organization-managed install, where Claude Code's built-in guard (`sec-default`) keeps an installed mod
from changing the system prompt and from `prompt.compose` / `classic.PermissionRequest`. So the probe uses the hooks the
guard allows (`prompt.submit` context for the briefing, `tool.check` to hold a permission prompt) and keeps the two
blocked ones only as detectors: a `fired.*` line in the log means that hook ran after all.

## Run it

In a scratch repo, with a real task id from `crook task list`:

```
SHEPHERD_TASK=<id> SHEPHERD_PROBE_PERMS=hold \
  claude --plugin-dir ~/Dev/shepherd/spike/shepherd-probe --remote-control probe
```

`SHEPHERD_PROBE_PERMS` is `hold` (wait for an answer, see check 4) or anything else to only log that a prompt was asked.
`--remote-control` makes the session visible to the phone.

## Checks

| # | Do | Look for | Answers |
|---|---|---|---|
| 0 | Start the session, send one prompt, ask for a Bash command | `cat ~/.shepherd-probe/log.jsonl`: are there `fired.prompt.compose` / `fired.classic.PermissionRequest` lines? Probably not, which confirms the guard. Also `claude --debug` for a line naming `cc-plugin-sec-default` | Guard |
| 1 | Ask "what is your task?" | It describes the task: the briefing arrived through `prompt.submit` context. Log has `session.start` with `crookExit: 0` and `brief.attached` | Q3 |
| 2 | Ask it to call `probe_log` with a message, then `crook task show <id>` | The message is in the task log | Q3 |
| 3 | Ask it to call `probe_close` | Denied with "only Adam can mark a task done" | Q3 |
| 4 | With `hold`, ask it to run `date` in Bash. From a second terminal run `echo allow > ~/.shepherd-probe/decision` | Log: `perm.asked` then `perm.answered` with `afterMs`; the command runs. Note whether the terminal dialog is hidden while the hook waits | Q2 |
| 5 | Repeat 4 with `SHEPHERD_PROBE_WAIT_MS` of 5000, 60000 and 600000. While the hook waits, look at the phone | Does the hook outlive the wait. Does the phone show the permission prompt while the hook holds it (probably not: the engine has not asked yet). Does the phone's push still fire. Then run without `hold` and answer on the phone | Q2 |
| 6 | `/probe` in the terminal; press Ping in the band and pane. Then open the session on the phone | Log `press` rows with `surface: terminal`. The docs say the mod's drawing stays in the terminal under Remote Control, so expect nothing on the phone; type `/probe` from the phone and see whether a text reply comes back | Q1 |
| 7 | `/probe send <other session id> hello` | The other session receives it; log `session.send` | Q2 |
| 8 | `/exit`, then start again and close the terminal tab with ⌘W | Log `session.end.model` with `ms` and `answered`; is anything logged at all after ⌘W | Q3 |

Record each as works / works with a catch / fails, in `docs/mods-spike.md`.
