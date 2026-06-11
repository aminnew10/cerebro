import os
import sys

pgid_file = sys.argv[1]
cmd = sys.argv[2:]

if not cmd:
    sys.exit("exec_setsid: missing command")

os.setsid()
with open(pgid_file, "w") as fh:
    fh.write(str(os.getpgrp()))

os.execvp(cmd[0], cmd)
