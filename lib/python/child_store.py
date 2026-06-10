# Child-session store CLI: `child_store.py <file> <op> [args...]`. Ops:
#   begin <key> <provider> <role> <repo> <branch> <log> <ts>  -- mark running
#   set-id <key> <provider> <id> <ts>                          -- record the id
#   done <key> <ts>                                            -- mark finished
#   get <key>                  -- print the stored id (empty if none)
#   fresh <key> <ttl>          -- exit 0 if updated_at within ttl, else 1
#   list-running <ttl>         -- TSV of still-fresh status=running entries
#   match <ttl> <role> <repo>  -- TSV of still-fresh entries with an id
import os, sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from child_store_lib import _fresh, _load, store_upsert

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
