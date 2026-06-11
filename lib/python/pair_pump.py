# The input-pump for a paired child (`--pair`). stdin carries the initial
# prompt; argv is <fifo> <steer_path> <child_log> <idle_grace> <pgid_file>
# <stall_secs> <stall_busy_secs>. It emits the prompt as the first stream-json
# user message, then watches <child_log> for the `result` event that ends each
# turn. After
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
#     SIZE growth. If the log stops growing the turn MAY be STALLED -- but the
#     decision is IDLE-GATED with two tiers, because the real incident that
#     motivated this was an IDLE generation stall, not a stuck command: every
#     issued tool_use had its tool_result back (the final Playwright
#     browser_click DID return) and only THEN did the agent go silent with
#     nothing in flight. Pure size/silence detection wrongly reaps legitimately
#     long SILENT commands (docker compose up -d --build, a test suite, a
#     Playwright call still running). So the pump also tracks whether a command
#     is in flight (an issued tool_use with no matching tool_result yet) and:
#       - IDLE (nothing in flight) + silent for <stall_secs>      -> STALLED
#       - BUSY (command in flight) + silent for <stall_busy_secs> -> STALLED
#     On STALLED the pump reaps ONLY the child's process group (proved via
#     <pgid_file>, written by exec_setsid.py), writes a synthetic terminal
#     `result` event into <child_log> (for `observe` rendering) plus a distinct
#     `${child_log%.jsonl}.stalled` sidecar (the wrapper's authoritative stall
#     signal), then exits. CEREBRO_PAIR_STALL tunes <stall_secs> (default 90,
#     AGGRESSIVE -- the idle tier); CEREBRO_PAIR_STALL_BUSY tunes
#     <stall_busy_secs> (default 900, GENEROUS -- the in-flight grace).

import base64, json, os, select, signal, sys, time

fifo, steer_path, child_log = sys.argv[1], sys.argv[2], sys.argv[3]
idle_grace = float(sys.argv[4])
pgid_file = sys.argv[5]
stall_secs = float(sys.argv[6])
stall_busy_secs = float(sys.argv[7])

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

def command_in_flight():
    # A command is "in flight" iff some issued tool_use has not yet produced a
    # matching tool_result. Scan child_log: assistant message content blocks of
    # type tool_use contribute their `id` to `issued`; user message content
    # blocks of type tool_result contribute their `tool_use_id` to `returned`.
    # in_flight = (issued - returned) is non-empty. Called only when a stall is
    # otherwise imminent (silence already past the idle threshold), so this full
    # re-scan stays off the hot path -- consistent with turns_completed's style.
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
        else:
            # Two-tier, IDLE-GATED stall. Size growth alone cannot tell a true
            # hang from a legitimately long SILENT command, so gate on whether a
            # command is in flight. The real incident was an IDLE generation
            # stall (all tool_results back, then silence with nothing running),
            # so reap a quiet IDLE agent aggressively at stall_secs; give an
            # in-flight command the generous stall_busy_secs grace before
            # reaping. command_in_flight() is evaluated only once silence has
            # already crossed the idle threshold, keeping it off the hot path.
            silence = time.monotonic() - last_grew
            if silence >= stall_secs:
                if (not command_in_flight()) or silence >= stall_busy_secs:
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
