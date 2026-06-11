# Launch a paired child in its OWN session/process group and record its PGID,
# so the stall watchdog (pair_pump.py) can reap the whole child subtree --
# claude plus every MCP/browser process it spawns -- with a single killpg,
# without ever touching cerebro's own group. macOS ships no setsid(1), so this
# is the portable shim. argv is <pidfile> <cmd...>.
#
# os.setsid() makes this process a new session+group leader, so its pid IS the
# new pgid; we record that pid, then os.execvp() the real command, which keeps
# the same pid -> the recorded value stays the group's pgid for its lifetime.
# (In cerebro's non-interactive pipeline a stage is not already a group leader,
# so setsid() succeeds.)
import os, sys

pidfile, cmd = sys.argv[1], sys.argv[2:]
os.setsid()
with open(pidfile, "w") as f:
    f.write(str(os.getpid()))
os.execvp(cmd[0], cmd)
