Fixtures captured verbatim from a live `herdr 0.9.0` instance (protocol 22) on 2026-09-17,
via `~/.config/herdr/herdr.sock`. Each file is one JSON-RPC-style frame (or several
newline-delimited frames) exactly as received — no reformatting.

- `session_snapshot.jsonl` — response to `session.snapshot`, full state dump.
- `ping_response.jsonl` — response to `ping`, a minimal well-formed success envelope.
- `error_response.jsonl` — response to an unknown method name. Note `"id":""` — Herdr
  can't echo the request id back when the method itself fails to parse.
- `subscribe_ack_and_pane_updated_burst.jsonl` — the `events.subscribe` ACK
  (`{"result":{"type":"subscription_started"}}`) followed by a burst of `pane_updated`
  events from one working agent, captured over ~4s. Demonstrates the firehose: many
  frames for one continuously-running agent, most differing only in scrollback-derived
  fields, not `agent_status`.

Not yet captured: a `pane_agent_status_changed` event (the precise per-pane subscription
Shepherd prefers over the firehose). Triggering one requires actually changing a live
agent's status, which wasn't safe to do while capturing fixtures. Phase 2 step 8 verifies
this subscription fires for real, at which point capture a fixture from that observation.
