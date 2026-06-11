# The input-pump for a paired child (`--pair`). stdin carries the initial
# prompt; argv is <fifo> <steer_path> <child_log> <idle_grace> <pgid_file>
# <stall_secs> <stall_busy_secs>. It emits the prompt as the first stream-json
# user message, then watches <child_log> for the `result` event that ends each
# turn. After each turn it waits up to <idle_grace> seconds for a one-shot
# `cerebro steer` message to arrive over <fifo> ("S <base64>" per message);
# each message is forwarded as the next user turn and appended to <steer_path>,
# and resets the window. A quiet window closes claude's stdin so the child
# finishes.
#
# Liveness: while a turn is in progress, the pump tracks child-log growth. If
# the log freezes, an idle agent is killed after <stall_secs>; an agent with a
# tool_use still awaiting a matching tool_result gets <stall_busy_secs>. This
# bounds the Claude stream freeze seen in dogfooding without prematurely killing
# legitimately long silent commands.

import base64, json, os, select, signal, sys, time

fifo, steer_path, child_log = sys.argv[1], sys.argv[2], sys.argv[3]
idle_grace = float(sys.argv[4])
pgid_file = sys.argv[5] if len(sys.argv) > 5 else ""
stall_secs = float(sys.argv[6]) if len(sys.argv) > 6 and sys.argv[6] else 90.0
stall_busy_secs = float(sys.argv[7]) if len(sys.argv) > 7 and sys.argv[7] else 420.0

def emit(text):
    try:
        sys.stdout.write(json.dumps(
            {"type": "user", "message": {"role": "user", "content": text}},
            ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, OSError):
        return False
    return True

def downstream_open():
    p = select.poll()
    p.register(sys.stdout.fileno(), select.POLLOUT)
    for _fd, revents in p.poll(0):
        if revents & (select.POLLHUP | select.POLLERR | select.POLLNVAL):
            return False
    return True

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

def command_in_flight():
    issued, returned = set(), set()
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
                etype = ev.get("type")
                content = (ev.get("message") or {}).get("content")
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if etype == "assistant" and block.get("type") == "tool_use":
                        bid = block.get("id")
                        if bid is not None:
                            issued.add(bid)
                    elif etype == "user" and block.get("type") == "tool_result":
                        tid = block.get("tool_use_id")
                        if tid is not None:
                            returned.add(tid)
    except OSError:
        pass
    return bool(issued - returned)

def read_child_pgid():
    try:
        with open(pgid_file) as f:
            pgid = int(f.read().strip())
    except (OSError, ValueError):
        return None
    if pgid <= 1 or pgid == os.getpgrp():
        return None
    return pgid

def reap_child():
    pgid = read_child_pgid()
    if pgid is None:
        return
    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, OSError):
        return
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            os.killpg(pgid, 0)
        except (ProcessLookupError, OSError):
            return
        time.sleep(0.1)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, OSError):
        pass

def mark_stalled():
    try:
        with open(child_log, "a") as fh:
            fh.write('{"type":"result","subtype":"stalled","is_error":true}\n')
    except OSError:
        pass
    marker = (child_log[:-6] if child_log.endswith(".jsonl") else child_log) + ".stalled"
    try:
        with open(marker, "w"):
            pass
    except OSError:
        pass

if not emit(sys.stdin.read()):
    sys.exit(0)

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
idle_deadline = None
last_size = os.path.getsize(child_log) if os.path.exists(child_log) else 0
last_grew = time.monotonic()

while True:
    refill()
    if not downstream_open():
        sys.exit(0)

    completed = turns_completed()

    if idle_deadline is None:
        sz = os.path.getsize(child_log) if os.path.exists(child_log) else 0
        if sz > last_size:
            last_size, last_grew = sz, time.monotonic()
        if completed > done_turns:
            done_turns = completed
            idle_deadline = time.monotonic() + idle_grace
        else:
            silence = time.monotonic() - last_grew
            if silence >= stall_secs:
                if (not command_in_flight()) or silence >= stall_busy_secs:
                    reap_child()
                    mark_stalled()
                    sys.exit(0)
    else:
        if completed > done_turns:
            done_turns = completed
        if pending:
            msg = pending.pop(0)
            if not emit(msg):
                sys.exit(0)
            try:
                with open(steer_path, "a") as sf:
                    sf.write("- " + msg.replace("\n", "\n  ") + "\n")
            except OSError:
                pass
            idle_deadline = None
            last_size = os.path.getsize(child_log) if os.path.exists(child_log) else 0
            last_grew = time.monotonic()
        elif time.monotonic() >= idle_deadline:
            sys.exit(0)

    time.sleep(0.3)
