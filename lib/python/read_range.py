# Ranged file read for `cerebro read --range`: argv is <path> <lo:hi> where
# either side may be blank for open-ended; 1-indexed inclusive.
import sys
path, rng = sys.argv[1], sys.argv[2]
lo, _, hi = rng.partition(":")
lo = int(lo) if lo else 1
hi = int(hi) if hi else None
with open(path) as f:
    for i, line in enumerate(f, 1):
        if i < lo:
            continue
        if hi is not None and i > hi:
            break
        sys.stdout.write(line)
