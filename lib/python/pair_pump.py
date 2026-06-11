# The input-pump for a paired child (`--pair`). stdin carries the initial
# prompt; argv is <fifo> <steer_path> <child_log> <idle_grace>. It emits the
# prompt as the first stream-json user message, then watches <child_log> for
# the `result` event that ends each turn. After each turn it waits up to
# <idle_grace> seconds for a one-shot `cerebro steer` message to arrive over
# <fifo> ("S <base64>" per message); each message is forwarded as the next
# user turn and appended to <steer_path>, and resets the window. A quiet
# window closes claude's stdin so the child finishes. The child therefore
# runs to completion on its own, with a short steering window after every
# turn -- no developer needs to stay attached.

import base64, json, os, sys, time

fifo, steer_path, child_log = sys.argv[1], sys.argv[2], sys.argv[3]
idle_grace = float(sys.argv[4])

def emit(text):
    sys.stdout.write(json.dumps(
        {"type": "user", "message": {"role": "user", "content": text}},
        ensure_ascii=False) + "\n")
    sys.stdout.flush()

def turns_completed():
    n = 0
    try:
        with open(child_log) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if ev.get("type") == "result":
                    n += 1
    except OSError:
        pass
    return n

emit(sys.stdin.read())

# O_RDWR keeps a writer fd open on our side so the pipe never reports EOF as
# one-shot `cerebro steer` writers come and go, and never blocks on open.
fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
buf = b""
pending = []

def refill():
    global buf
    try:
        chunk = os.read(fd, 65536)
    except (BlockingIOError, OSError):
        return
    if not chunk:
        return
    buf += chunk
    while b"\n" in buf:
        raw, buf = buf.split(b"\n", 1)
        s = raw.decode("utf-8", "replace").strip()
        if s.startswith("S "):
            try:
                pending.append(base64.b64decode(s[2:]).decode("utf-8", "replace"))
            except Exception:
                pass

done_turns = 0
while True:
    # Wait for the agent to finish the turn our last message started, draining
    # any steering that lands mid-turn so it is never lost. A hung turn is
    # bounded by cerebro's outer timeout, not here.
    while turns_completed() <= done_turns:
        refill()
        time.sleep(0.4)
    done_turns = turns_completed()
    # Offer to steer: wait up to idle_grace for a one-shot `cerebro steer`
    # message. Each message resets the window; a quiet window finishes the child.
    deadline = time.monotonic() + idle_grace
    while True:
        refill()
        if pending:
            msg = pending.pop(0)
            emit(msg)
            try:
                with open(steer_path, "a") as sf:
                    sf.write("- " + msg.replace("\n", "\n  ") + "\n")
            except OSError:
                pass
            break  # wait for the steered turn to complete, then re-offer
        if time.monotonic() >= deadline:
            sys.exit(0)
        time.sleep(0.3)
