# Codex stream capture: `codex_capture.py <json_path> [store] [key]`. Tees
# codex's --json stream to <json_path> (for the post-run early-rejection
# check) and, the moment the first `thread.started` event arrives, persists
# the resumable thread_id to the store -- so an interrupted review is
# resumable too.
import json, os, sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from child_store_lib import _now_iso, store_upsert

json_path = sys.argv[1]
store_file = sys.argv[2] if len(sys.argv) > 2 else ""
child_key = sys.argv[3] if len(sys.argv) > 3 else ""
captured = False
with open(json_path, "w") as out:
    for line in sys.stdin:
        out.write(line)
        out.flush()
        if captured or not (store_file and child_key):
            continue
        s = line.strip()
        if not s:
            continue
        try:
            ev = json.loads(s)
        except Exception:
            continue
        if ev.get("type") == "thread.started":
            tid = ev.get("thread_id")
            if tid:
                store_upsert(store_file, child_key,
                             {"id": tid, "provider": "codex", "updated_at": _now_iso()})
                captured = True
