#!/usr/bin/env python3
import json
import os
import sys
import tempfile
import time

STATE_DIR = os.path.expanduser("~/.shepherd/state")
STALE_SWEEP_AFTER_HOURS = 24

# tools that block on a human decision but aren't "permission" in the
# ordinary sense - discovered in increment 2, AskUserQuestion surfaces
# as notification_type=permission_prompt just like a normal tool, so the
# discriminator has to be tool_name, not notification_type.
QUESTION_TOOLS = {"AskUserQuestion", "ExitPlanMode"}


def summarize_todos(todos):
    total = len(todos)
    done = sum(1 for t in todos if t.get("status") == "completed")
    active = next((t.get("activeForm") for t in todos if t.get("status") == "in_progress"), None)
    return {"done": done, "total": total, "activeForm": active}


def read_state(session_id):
    path = os.path.join(STATE_DIR, f"{session_id}.json")
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def extract_ask_user_question(tool_input):
    # AskUserQuestion's own input already carries the exact question text
    # and labeled options Claude Code will render, in the same order it
    # numbers them - no need to guess or parse the rendered terminal text.
    # Only the first question is read: Shepherd's blocked-state model is
    # one question per session, and multi-question batches are rare.
    questions = (tool_input or {}).get("questions") or []
    if not questions:
        return {}
    first = questions[0]
    options = [opt.get("label") for opt in (first.get("options") or []) if opt.get("label")]
    detail = {}
    if first.get("question"):
        detail["question"] = first["question"]
    if options:
        detail["options"] = options
    if first.get("multiSelect"):
        detail["multi_select"] = True
    return detail


def summarize_permission_request(tool_name, tool_input):
    # What's actually being approved, one line - captured live from a real
    # PermissionRequest payload per tool: Bash carries a `description` (a
    # short human summary Claude itself writes) or falls back to the raw
    # `command`; Write/Edit/NotebookEdit carry `file_path`; WebFetch/WebSearch
    # carry the URL or query. Unrecognised tools fall back to just the tool
    # name - better than nothing, but see the `needs-permission` branch
    # below for why that's still shown alongside, not hidden.
    tool_input = tool_input or {}
    if tool_name == "Bash":
        detail = tool_input.get("description") or tool_input.get("command")
    elif tool_name in ("Write", "Edit", "NotebookEdit"):
        detail = tool_input.get("file_path")
    elif tool_name == "WebFetch":
        detail = tool_input.get("url")
    elif tool_name == "WebSearch":
        detail = tool_input.get("query")
    else:
        detail = None
    return f"{tool_name}: {detail}" if detail else tool_name


def resolve_state(payload, existing):
    hook_event_name = payload.get("hook_event_name")
    notification_type = payload.get("notification_type")
    tool_name = payload.get("tool_name")
    tool_input = payload.get("tool_input")

    if hook_event_name == "PermissionRequest":
        if tool_name in QUESTION_TOOLS:
            detail = {"tool_name": tool_name}
            if tool_name == "AskUserQuestion":
                detail.update(extract_ask_user_question(tool_input))
            return "asked-a-question", detail
        return "needs-permission", {
            "tool_name": tool_name,
            "summary": summarize_permission_request(tool_name, tool_input),
        }

    if hook_event_name == "Notification":
        if notification_type == "idle_prompt":
            return "idle", {}
        if notification_type == "agent_needs_input":
            return "asked-a-question", {}
        # permission_prompt is a delayed "still waiting" echo of a
        # PermissionRequest we already recorded with a better detail - no-op.
        return None, None

    if hook_event_name == "UserPromptSubmit":
        # a fresh prompt clears any leftover todo memory from a prior turn.
        return "working", {}

    if hook_event_name == "Stop":
        # increment 2 found no dedicated "resolved" event - Stop is the
        # only reliable clearer of a stale blocked/question state. It's
        # also the only place "stalled" (stopped with unfinished todos)
        # can be derived, since it needs both the lifecycle edge and the
        # last-known todo counts together.
        todos = (existing or {}).get("detail", {}).get("todos")
        if todos and todos.get("total", 0) > 0 and todos.get("done", 0) < todos.get("total", 0):
            return "stalled", {"todos": todos}
        return "idle", {}

    if hook_event_name == "PostToolUse" and tool_name == "TodoWrite":
        todos = payload.get("tool_input", {}).get("todos", [])
        summary = summarize_todos(todos)
        # a todo update doesn't change the coarse lifecycle state - the
        # session is still whatever it was (almost always "working") -
        # it just attaches the latest progress for a later Stop to read.
        carried_state = (existing or {}).get("state") or "working"
        return carried_state, {"todos": summary}

    return None, None


def prune_session(session_id):
    path = os.path.join(STATE_DIR, f"{session_id}.json")
    try:
        os.unlink(path)
    except OSError:
        pass


def sweep_stale_files():
    # crash safety net for sessions that never fired SessionEnd (killed
    # pane, crashed terminal, machine sleep/wake weirdness). Cheap: the
    # state dir has at most a few dozen entries.
    try:
        names = os.listdir(STATE_DIR)
    except OSError:
        return
    now = time.time()
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(STATE_DIR, name)
        try:
            if now - os.path.getmtime(path) > STALE_SWEEP_AFTER_HOURS * 3600:
                os.unlink(path)
        except OSError:
            pass


def write_state(session_id, state, detail):
    os.makedirs(STATE_DIR, exist_ok=True)
    path = os.path.join(STATE_DIR, f"{session_id}.json")
    doc = {
        "schema": 1,
        "session_id": session_id,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "state": state,
        "detail": detail,
    }
    fd, tmp_path = tempfile.mkstemp(dir=STATE_DIR, prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f)
        os.rename(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return

    if payload.get("agent_id"):
        return
    if payload.get("hook_event_name") == "SubagentStop":
        return

    session_id = payload.get("session_id")
    if not session_id:
        return

    sweep_stale_files()

    if payload.get("hook_event_name") == "SessionEnd":
        prune_session(session_id)
        return

    existing = read_state(session_id)
    state, detail = resolve_state(payload, existing)
    if state is None:
        return

    write_state(session_id, state, detail)


if __name__ == "__main__":
    main()
