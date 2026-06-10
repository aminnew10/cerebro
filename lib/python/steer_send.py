# One-shot steering inject for `cerebro steer`. argv is <fifo> <message>.
# It writes a single "S <base64>" line to the child's pipe and returns;
# the pump forwards it as the child's next user turn.

import base64, os, sys
fifo, msg = sys.argv[1], sys.argv[2]
try:
    fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
except OSError:
    sys.stderr.write("cerebro: the child is not listening (it may have finished).\n")
    sys.exit(3)
try:
    os.write(fd, ("S " + base64.b64encode(msg.encode("utf-8")).decode() + "\n").encode())
finally:
    os.close(fd)
