# cerebro lib: python
# inline python helpers shared across child-session persistence and stream parsing
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- inline python helpers -----------------------------------------------

# Shared child-session store library. Prepended to every python program that
# touches child-sessions.json (the store CLI, the claude stream parser, the
# codex stream capture) so the id a child emits at startup is persisted the
# INSTANT it is known -- not at the end of the run -- and an interrupt
# therefore leaves a resumable pointer. All writes take an exclusive flock on
# a sidecar .lock file and rewrite the JSON atomically, so concurrent --pair
# children persisting their own ids never clobber each other.
PY_CHILD_STORE_LIB='
import json, sys, os, time, calendar, tempfile
try:
    import fcntl
    _HAVE_FCNTL = True
except Exception:
    _HAVE_FCNTL = False

def _now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def _fresh(ts, ttl):
    try:
        t = calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return False
    return (time.time() - t) <= ttl

def _load(f):
    try:
        with open(f) as fh:
            return json.load(fh)
    except Exception:
        return {}

def _atomic_write(f, data):
    d = os.path.dirname(f) or "."
    fd, tmp = tempfile.mkstemp(dir=d)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, f)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass

def store_upsert(f, key, fields):
    lf = open(f + ".lock", "w")
    try:
        if _HAVE_FCNTL:
            fcntl.flock(lf, fcntl.LOCK_EX)
        data = _load(f)
        entry = data.get(key) or {}
        entry.update(fields)
        data[key] = entry
        _atomic_write(f, data)
    finally:
        try:
            if _HAVE_FCNTL:
                fcntl.flock(lf, fcntl.LOCK_UN)
        except OSError:
            pass
        lf.close()
'

# child-session store CLI. `child_store <file> <op> [args...]`. Ops:
#   begin <key> <provider> <role> <repo> <branch> <log> <ts>  -- mark running
#   set-id <key> <provider> <id> <ts>                          -- record the id
#   done <key> <ts>                                            -- mark finished
#   get <key>                  -- print the stored id (empty if none)
#   fresh <key> <ttl>          -- exit 0 if updated_at within ttl, else 1
#   list-running <ttl>         -- TSV of still-fresh status=running entries
PY_CHILD_STORE="$PY_CHILD_STORE_LIB"'
f = sys.argv[1]
op = sys.argv[2]
if op == "begin":
    key, provider, role, repo, branch, log, ts = sys.argv[3:10]
    store_upsert(f, key, {"provider": provider, "role": role, "repo": repo,
                          "branch": branch, "log": log, "status": "running",
                          "started_at": ts, "updated_at": ts})
elif op == "set-id":
    key, provider, cid, ts = sys.argv[3:7]
    if cid:
        store_upsert(f, key, {"id": cid, "provider": provider, "updated_at": ts})
elif op == "done":
    key, ts = sys.argv[3:5]
    store_upsert(f, key, {"status": "done", "updated_at": ts})
elif op == "get":
    e = _load(f).get(sys.argv[3]) or {}
    sys.stdout.write(e.get("id") or "")
elif op == "fresh":
    e = _load(f).get(sys.argv[3]) or {}
    ts = e.get("updated_at") or ""
    sys.exit(0 if (ts and _fresh(ts, int(sys.argv[4]))) else 1)
elif op == "list-running":
    ttl = int(sys.argv[3])
    for key, e in _load(f).items():
        if e.get("status") == "running" and _fresh(e.get("updated_at") or "", ttl):
            sys.stdout.write("\t".join([
                key, e.get("role") or "", e.get("repo") or "",
                e.get("branch") or "", e.get("log") or "",
                e.get("started_at") or e.get("updated_at") or "",
            ]) + "\n")
elif op == "match":
    # match <ttl> <role> <repo> -- TSV(key, id, branch, status, updated_at)
    # for every still-fresh entry with a stored id that has this role+repo.
    # Used by `cerebro answer` to locate the session to resume when the
    # orchestrator does not pass an explicit discriminator.
    ttl = int(sys.argv[3]); role = sys.argv[4]; repo = sys.argv[5]
    for key, e in _load(f).items():
        if (e.get("role") == role and e.get("repo") == repo and e.get("id")
                and _fresh(e.get("updated_at") or "", ttl)):
            sys.stdout.write("\t".join([
                key, e.get("id") or "", e.get("branch") or "",
                e.get("status") or "", e.get("updated_at") or "",
            ]) + "\n")
else:
    sys.exit(2)
'

# codex stream capture. `python3 -c "$PY_CODEX_CAPTURE" <json_path> [store] [key]`.
# Tees codex`s --json stream to <json_path> (for the post-run early-rejection
# check) and, the moment the first `thread.started` event arrives, persists the
# resumable thread_id to the store -- so an interrupted review is resumable too.
PY_CODEX_CAPTURE="$PY_CHILD_STORE_LIB"'
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
'

# Stream-json parser shared by plan / execute / apply-review / doc-write.
# Reads claude stream-json on stdin, emits a one-line tool-call summary on
# stderr per tool use, captures the final `result` event`s text to the
# given file path (if non-empty), captures the child`s session_id to the
# optional second path (if non-empty) AND -- when a store file + key are
# given -- persists it to the store at init so an interrupt stays resumable,
# and exits non-zero if claude reported anything other than a successful
# result.
PY_PARSE_STREAM="$PY_CHILD_STORE_LIB"'
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
'

