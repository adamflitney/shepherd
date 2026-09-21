#!/bin/sh
# Shepherd increment 2: event-order observatory.
# Appends one JSONL line per hook invocation to ~/.shepherd/events.jsonl.
# Deliberately dumb: no state, no filtering, just capture for analysis.
mkdir -p "$HOME/.shepherd"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat | jq -c --arg ts "$ts" '{
  ts: $ts,
  hook_event_name: .hook_event_name,
  notification_type: .notification_type,
  tool_name: .tool_name,
  session_id: .session_id,
  agent_id: .agent_id
}' >> "$HOME/.shepherd/events.jsonl"
