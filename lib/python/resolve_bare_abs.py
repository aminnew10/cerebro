# Resolve argv[1] (an absolute path) for a bare-abs read/grep/ls invocation.
# Prints the realpathed result on stdout. Exit codes: 3 if not absolute
# (internal misuse only); 6 if it resolves under /dev /proc /sys (special
# filesystems / blocking devices) -- a security refusal callers MUST keep
# hard; 7 for a benign missing path or wrong type (no regular file or
# directory: FIFO, socket, char/block device) which callers may translate
# into a successful empty result.
import os, stat, sys
p = sys.argv[1]
if not os.path.isabs(p):
    sys.stderr.write(f"cerebro: error: path must be absolute: {p}\n")
    sys.exit(3)
try:
    r = os.path.realpath(p)
    st = os.stat(r)
except OSError as e:
    # Benign-eligible "missing" -- distinct sentinel so bridges can route
    # only this case through missing_target (security stays hard).
    sys.stderr.write(f"cerebro: error: cannot stat {p}: {e}\n")
    sys.exit(7)
for special in ("/dev/", "/proc/", "/sys/"):
    if r == special.rstrip("/") or r.startswith(special):
        sys.stderr.write(f"cerebro: error: refusing to read special path: {r}\n")
        sys.exit(6)
m = st.st_mode
if not (stat.S_ISREG(m) or stat.S_ISDIR(m)):
    # Benign-eligible "wrong type".
    sys.stderr.write(f"cerebro: error: not a regular file or directory: {r}\n")
    sys.exit(7)
print(r)
