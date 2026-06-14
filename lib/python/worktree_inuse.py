# worktree_inuse.py <child-sessions-file> <wt> <key> <ttl> -- exit 0 if a
# still-fresh status=running child record in <file> belongs to worktree <wt>:
# either its store key equals <key> (the owning execute child, whose worktree
# dir name IS its child key) or its recorded repo path equals <wt> (a follow-up
# review / apply-review / doc-write addressed by the worktree). Exit 1 otherwise.
# Used by `cerebro worktrees` to keep a worktree that still has an in-flight or
# resumable cerebro child.
import os, sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from child_store_lib import _fresh, _load

f, wt, key, ttl = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
for k, e in _load(f).items():
    if e.get("status") != "running":
        continue
    ts = e.get("updated_at") or ""
    if not (ts and _fresh(ts, ttl)):
        continue
    if k == key or (e.get("repo") or "") == wt:
        sys.exit(0)
sys.exit(1)
