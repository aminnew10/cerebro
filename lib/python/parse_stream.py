# Stream-json parser shared by plan / execute / apply-review / doc-write:
# `parse_stream.py <result_path> <id_path> [store] [key]`. Reads claude
# stream-json on stdin, emits a one-line tool-call summary on stderr per
# tool use, captures the final `result` event's text to <result_path> (if
# non-empty), captures the child's session_id to <id_path> (if non-empty)
# AND -- when a store file + key are given -- persists it to the store at
# init so an interrupt stays resumable. Exits non-zero if claude reported
# anything other than a successful result.
import json, os, sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from child_store_lib import _now_iso, store_upsert

result_path = sys.argv[1] if len(sys.argv) > 1 else ""
id_path = sys.argv[2] if len(sys.argv) > 2 else ""
store_file = sys.argv[3] if len(sys.argv) > 3 else ""
child_key = sys.argv[4] if len(sys.argv) > 4 else ""
result_text = None
result_subtype = None
saw_any_event = False

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    saw_any_event = True
    t = ev.get("type")
    if t == "system" and ev.get("subtype") == "init":
        sid = ev.get("session_id")
        if sid and id_path:
            try:
                with open(id_path, "w") as f:
                    f.write(sid)
            except OSError:
                pass
        if sid and store_file and child_key:
            store_upsert(store_file, child_key,
                         {"id": sid, "provider": "claude", "updated_at": _now_iso()})
    if t == "assistant":
        for item in ev.get("message", {}).get("content", []) or []:
            if item.get("type") == "tool_use":
                name = item.get("name", "?")
                inp = item.get("input", {}) or {}
                target = (
                    inp.get("description") or inp.get("file_path") or
                    inp.get("pattern") or inp.get("path") or
                    inp.get("query") or inp.get("command") or ""
                )
                if isinstance(target, list):
                    target = " ".join(map(str, target))
                target = str(target).replace("\n", " ").strip()
                if len(target) > 120:
                    target = target[:120] + "..."
                clr = "\r\033[2K" if sys.stderr.isatty() else ""
                sys.stderr.write(f"{clr}  {name}: {target}\n")
                sys.stderr.flush()
    elif t == "result":
        result_subtype = ev.get("subtype")
        result_text = ev.get("result")

if not saw_any_event:
    sys.stderr.write("\ncerebro: claude produced no stream events\n")
    sys.exit(2)
if result_subtype and result_subtype != "success":
    sys.stderr.write(f"\ncerebro: claude reported result subtype={result_subtype}\n")
    sys.exit(4)
if result_path:
    if result_text is None:
        sys.stderr.write(f"\ncerebro: claude did not emit a result event\n")
        sys.exit(3)
    with open(result_path, "w") as f:
        f.write(result_text)
