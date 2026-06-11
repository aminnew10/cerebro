# The input-pump for a paired child (`--pair`). stdin carries the initial
# prompt; argv is <fifo> <steer_path> <child_log> <idle_grace> <pgid_file>
# <stall_secs>. It emits the prompt as the first stream-json user message,
# then watches <child_log> for the `result` event that ends each turn. After
# each turn it waits up to <idle_grace> seconds for a one-shot `cerebro steer`
# message to arrive over <fifo> ("S <base64>" per message); each message is
# forwarded as the next user turn and appended to <steer_path>, and resets the
# window. A quiet window closes claude's stdin so the child finishes. The child
# therefore runs to completion on its own, with a short steering window after
# every turn -- no developer needs to stay attached.
#
# Two liveness guarantees beyond the steering window:
#   * Downstream close: if claude's stdin pipe goes away (the child exited
#     without ever emitting a terminating `result`) the pump exits promptly,
#     releasing the fifo so `observe`/`steer` stop reporting the child live.
#   * Stall watchdog: while a turn is in progress, the pump tracks <child_log>
#     SIZE growth. If the log stops growing for <stall_secs> the turn is
#     declared STALLED; the pump reaps ONLY the child's process group (proved
#     via <pgid_file>, written by exec_setsid.py), writes a synthetic terminal
#     `result` event into <child_log> (for `observe` rendering) plus a distinct
#     `${child_log%.jsonl}.stalled` sidecar (the wrapper's authoritative stall
#     signal), then exits. CEREBRO_PAIR_STALL tunes <stall_secs> (default 90,
#     AGGRESSIVE -- raise it for runs that block silently on builds/tests).

import base64, json, os, select, signal, sys, time

fifo, steer_path, child_log = sys.argv[1], sys.argv[2], sys.argv[3]
idle_grace = float(sys.argv[4])
pgid_file = sys.argv[5]
stall_secs = float(sys.argv[6])

def emit(text):
    # CPython ignores SIGPIPE, so a write to a closed reader raises rather than
    # killing us. Treat a dead downstream as "delivery failed" (False) so the
    # caller can stop; a steer is recorded only on a truthy emit.
    try:
        sys.stdout.write(json.dumps(
            {"type": "user", "message": {"role": "user", "content": text}},
            ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, OSError):
        return False
    return True

def downstream_open():
    # True while claude's stdin pipe (our stdout) still has a reader. A HUP/ERR
    # means the child exited; the pump should then quit even if no `result`
    # event ever arrived.
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

def reap_pgid():
    # Prove the recorded pgid is the child's own group before signalling it.
    # Anything we cannot prove -- unreadable/garbled file, pgid <= 1, or our
    # own group -- yields None so we NEVER kill cerebro itself.
    try:
        with open(pgid_file) as f:
            pgid = int(f.read().strip())
    except (OSError, ValueError):
        return None
    if pgid <= 1 or pgid == os.getpgrp():
        return None
    return pgid

def reap():
    pgid = reap_pgid()
    if pgid is None:
        return
    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, OSError):
        return  # already gone
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            os.killpg(pgid, 0)
        except (ProcessLookupError, OSError):
            return  # group vanished after SIGTERM
        time.sleep(0.1)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, OSError):
        pass

def mark_stalled():
    # Two sinks. (1) A synthetic terminal event in child_log so observe's
    # render() maps it to "(ended: stalled)" and parse_stream's pipe-EOF exits
    # non-zero. (2) The authoritative .stalled sidecar the wrapper keys off.
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

# Guard the initial-prompt emit: a downstream that is already gone means there
# is nothing to drive, so exit at once.
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

# Single delivery loop. `idle_deadline is None` means we are waiting for the
# current turn to complete; once it does we set a post-turn idle window. Steers
# that land mid-turn buffer in `pending` and are delivered the instant the turn
# completes -- never stranded. The stall watchdog runs only while a turn is in
# progress (idle_deadline is None), keyed on real child_log growth.
done_turns = turns_completed()
idle_deadline = None
last_size = os.path.getsize(child_log) if os.path.exists(child_log) else 0
last_grew = time.monotonic()

while True:
    refill()
    if not downstream_open():
        sys.exit(0)
    completed = turns_completed()

    if idle_deadline is None:
        # A turn is in progress: watch the log for growth; reap on a stall.
        sz = os.path.getsize(child_log) if os.path.exists(child_log) else 0
        if sz > last_size:
            last_size, last_grew = sz, time.monotonic()
        if completed > done_turns:
            done_turns = completed
            idle_deadline = time.monotonic() + idle_grace
        elif time.monotonic() - last_grew >= stall_secs:
            reap()
            mark_stalled()
            sys.exit(0)
    else:
        # Post-turn steering window.
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
            # Now waiting for the steered turn to complete; reset growth tracking.
            idle_deadline = None
            last_size = os.path.getsize(child_log) if os.path.exists(child_log) else 0
            last_grew = time.monotonic()
        elif time.monotonic() >= idle_deadline:
            sys.exit(0)

    time.sleep(0.3)
