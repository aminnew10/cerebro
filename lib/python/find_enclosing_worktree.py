# Walk upward from an absolute path (argv[1]) looking for an enclosing git
# worktree (a directory containing a `.git` file or directory). Prints the
# worktree root on stdout if found; exits non-zero otherwise. Bounded to 12
# levels so we don't traverse the entire filesystem.
import os, sys
p = os.path.realpath(sys.argv[1])
if os.path.isfile(p):
    p = os.path.dirname(p)
for _ in range(12):
    if os.path.exists(os.path.join(p, ".git")):
        print(p)
        sys.exit(0)
    parent = os.path.dirname(p)
    if parent == p:
        sys.exit(1)
    p = parent
sys.exit(1)
