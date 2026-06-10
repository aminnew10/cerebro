# Pretty-print the session spec history for `cerebro spec history`: argv[1]
# is spec-history.jsonl (one {ts,text} object per line, oldest first).
import json, sys
path = sys.argv[1]
n = 0
with open(path) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        n += 1
        print(f"=== version {n}  [{rec.get('ts', '?')}] ===")
        print(rec.get("text", ""))
        print()
print(f"--- {n} version(s) total ---")
