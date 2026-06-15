# Stream parser shared by execute / apply-review / doc-write / answer:
# `parse_stream.py <result_path> <id_path> [store] [key]`. Reads the JSON
# event stream of `opencode run --format json` on stdin (one event per line),
# emits a one-line tool-call summary on stderr per tool use, captures the
# final assistant message text to <result_path> (if non-empty), captures the
# opencode session id to <id_path> (if non-empty) AND -- when a store file +
# key are given -- persists it the instant it is first seen so an interrupt
# stays resumable. Exits non-zero if opencode produced no events or reported
# an error.
#
# opencode event shape (from `opencode run --format json`):
#   {"type":"step_start","sessionID":"ses_...","part":{...}}
#   {"type":"text","sessionID":"ses_...","part":{"type":"text","text":"..."}}
#   {"type":"tool_use","sessionID":"ses_...","part":{"type":"tool","tool":"write",
#        "callID":"...","state":{"status":"completed","input":{...},
#        "output":"...","title":"..."}}}
#   {"type":"step_finish","sessionID":"ses_...","part":{"reason":"stop"|"tool-calls"}}
#   {"type":"error","sessionID":"ses_...","error":{"name":"...","data":{"message":"..."}}}
# Every event carries the session id at top level; there is no separate init
# event, so we capture it from the first event we see. opencode exits 0 even on
# error, so a `type:error` event -- not the exit code -- is the failure signal.
import json, os, sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from child_store_lib import _now_iso, store_upsert

result_path = sys.argv[1] if len(sys.argv) > 1 else ""
id_path = sys.argv[2] if len(sys.argv) > 2 else ""
store_file = sys.argv[3] if len(sys.argv) > 3 else ""
child_key = sys.argv[4] if len(sys.argv) > 4 else ""

session_id = None
saw_any_event = False
saw_error = False
error_msg = ""
# Final assistant text = the text parts of the last step. We reset the buffer
# on each step boundary and snapshot it at each step_finish, so result_text
# ends up holding the closing message (a child that pauses ends with its
# question there).
cur_step_text = []
result_text = ""
tool_summary_open = True


def emit_tool_summary(line):
    global tool_summary_open
    if not tool_summary_open:
        return
    try:
        sys.stderr.write(line)
        sys.stderr.flush()
    except (BrokenPipeError, OSError):
        # The orchestrator sometimes previews `cerebro ... 2>&1 | head -6`.
        # A closed preview pipe must not kill this parser, because that would
        # also make tee stop draining opencode's stdout and freeze the child log.
        tool_summary_open = False
        try:
            sys.stderr = open(os.devnull, "w")
        except OSError:
            pass


def record_session(sid):
    if not sid:
        return
    if id_path:
        try:
            with open(id_path, "w") as f:
                f.write(sid)
        except OSError:
            pass
    if store_file and child_key:
        store_upsert(store_file, child_key,
                     {"id": sid, "provider": "opencode", "updated_at": _now_iso()})


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    saw_any_event = True

    sid = ev.get("sessionID")
    if sid and session_id is None:
        session_id = sid
        record_session(sid)

    t = ev.get("type")
    part = ev.get("part") or {}

    if t == "step_start":
        cur_step_text = []
    elif t == "text":
        txt = part.get("text")
        if isinstance(txt, str):
            cur_step_text.append(txt)
    elif t == "tool_use":
        name = part.get("tool", "?")
        state = part.get("state") or {}
        inp = state.get("input") or {}
        target = (
            state.get("title") or inp.get("description") or
            inp.get("filePath") or inp.get("file_path") or
            inp.get("pattern") or inp.get("path") or inp.get("query") or
            inp.get("command") or inp.get("url") or ""
        )
        if isinstance(target, list):
            target = " ".join(map(str, target))
        target = str(target).replace("\n", " ").strip()
        if len(target) > 120:
            target = target[:120] + "..."
        clr = "\r\033[2K" if sys.stderr.isatty() else ""
        emit_tool_summary(f"{clr}  {name}: {target}\n")
    elif t == "step_finish":
        snap = "".join(cur_step_text).strip()
        if snap:
            result_text = snap
    elif t == "error":
        saw_error = True
        err = ev.get("error") or {}
        data = err.get("data") or {}
        error_msg = data.get("message") or err.get("name") or "unknown error"

# A final flush in case the run ended mid-step without a closing step_finish.
_tail = "".join(cur_step_text).strip()
if _tail:
    result_text = _tail

if not saw_any_event:
    sys.stderr.write("\ncerebro: opencode produced no events\n")
    sys.exit(2)
if saw_error:
    sys.stderr.write(f"\ncerebro: opencode reported an error: {error_msg}\n")
    sys.exit(4)
if result_path:
    with open(result_path, "w") as f:
        f.write(result_text)
