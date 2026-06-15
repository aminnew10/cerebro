# The input-pump for a paired child (`--pair`), driving a child agent that runs
# under a headless `opencode serve`. stdin carries the initial prompt; argv is
#   <base_url> <session_id> <agent> <model> <fifo> <steer_path> <child_log>
#   <idle_grace> <stall_secs> <stall_busy_secs>
#
# It POSTs the initial prompt to the session, subscribes to the server's SSE
# event stream, and re-emits each assistant message part on stdout in the SAME
# shape as `opencode run --format json` (so the downstream `tee child_log |
# parse_stream.py` captures the session id + closing message, and `cerebro
# observe` can narrate the child_log). After each turn (a `session.idle` event)
# it waits up to <idle_grace> seconds for a one-shot `cerebro steer` message to
# arrive over <fifo> ("S <base64>" per message); each is POSTed as the next user
# turn and appended to <steer_path>, resetting the window. A quiet window ends
# the run. A frozen event stream is reaped (POST .../abort) and flagged stalled;
# an "R <base64>" restart line aborts and flags the child for a clean relaunch.
#
# Pure stdlib (urllib) so it has no dependencies beyond python3.

import base64, json, os, sys, threading, time, queue
import urllib.request, urllib.error

base_url   = sys.argv[1].rstrip("/")
session_id = sys.argv[2]
agent      = sys.argv[3]
model      = sys.argv[4]
fifo       = sys.argv[5]
steer_path = sys.argv[6]
child_log  = sys.argv[7]
idle_grace = float(sys.argv[8])
stall_secs = float(sys.argv[9]) if sys.argv[9] else 180.0
stall_busy_secs = float(sys.argv[10]) if len(sys.argv) > 10 and sys.argv[10] else 450.0


def log_err(msg):
    try:
        sys.stderr.write(msg.rstrip("\n") + "\n")
        sys.stderr.flush()
    except Exception:
        pass


def _post(path, payload):
    # Returns the HTTP status (0 on transport failure). A rejected request is
    # reported to stderr -- the pump's stderr is captured to a diagnostic
    # sidecar by pair_run -- so a bad payload is visible rather than swallowed.
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(base_url + path, data=data,
                                 headers={"content-type": "application/json"},
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode("utf-8", "replace")
        except Exception:
            detail = ""
        log_err(f"pair_pump: POST {path} -> HTTP {e.code} {e.reason}: {detail}")
        return e.code
    except Exception as e:
        log_err(f"pair_pump: POST {path} failed: {e!r}")
        return 0


def model_payload():
    # opencode serve expects model as an object {providerID, modelID}; the
    # CEREBRO_MODEL string is "<provider>/<model>" (e.g.
    # "github-copilot/claude-opus-4.8"). Split on the first slash. If it can't
    # be parsed into both halves, omit model entirely (the server falls back to
    # the session/agent default) rather than send a shape the server rejects.
    if not model or "/" not in model:
        if model:
            log_err(f"pair_pump: cannot parse model {model!r} as provider/model; "
                    "omitting model field")
        return None
    provider, _, model_id = model.partition("/")
    provider = provider.strip()
    model_id = model_id.strip()
    if not provider or not model_id:
        log_err(f"pair_pump: cannot parse model {model!r} as provider/model; "
                "omitting model field")
        return None
    return {"providerID": provider, "modelID": model_id}


def send_prompt(text):
    body = {"parts": [{"type": "text", "text": text}], "agent": agent}
    mp = model_payload()
    if mp:
        body["model"] = mp
    return _post(f"/session/{session_id}/prompt_async", body)


def abort_session():
    _post(f"/session/{session_id}/abort", {})


def serve_alive():
    # Cheap liveness probe. A SIGKILL'd server can leave the SSE socket
    # half-open (the streaming read blocks for ages), so we actively check the
    # health endpoint to decide whether the server is really gone.
    try:
        with urllib.request.urlopen(base_url + "/global/health", timeout=2):
            return True
    except Exception:
        return False


def emit(obj):
    try:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, OSError):
        return False
    return True


# ----- SSE reader thread ----------------------------------------------------
# Pushes translated run-format events onto a queue and tracks liveness. Roles
# are tracked per message id (from message.updated) so we only surface the
# assistant's own parts, never the user prompt echoed back.
ev_q = queue.Queue()
state = {"last_activity": time.monotonic(), "idle": False, "stop": False,
         "serve_dead": False}
roles = {}


def sse_loop():
    # Reconnect on transient drops, but if the server is persistently
    # unreachable (it died), flag it so the main loop can bail fast instead of
    # waiting out the long stall timeout on a corpse.
    fails = 0
    while not state["stop"]:
        try:
            req = urllib.request.Request(base_url + "/event")
            with urllib.request.urlopen(req, timeout=60) as resp:
                fails = 0
                for raw in resp:
                    if state["stop"]:
                        return
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    try:
                        ev = json.loads(line[5:].strip())
                    except ValueError:
                        continue
                    handle_event(ev)
        except Exception:
            if state["stop"]:
                return
            fails += 1
            if fails >= 10:
                state["serve_dead"] = True
                return
            time.sleep(0.5)


def handle_event(ev):
    t = ev.get("type") or ""
    props = ev.get("properties") or {}
    sid = props.get("sessionID") or (props.get("info") or {}).get("id")
    if sid and sid != session_id:
        return

    if t == "message.updated":
        info = props.get("info") or {}
        mid = info.get("id")
        role = info.get("role")
        if mid and role:
            roles[mid] = role
        return

    if t == "message.part.updated":
        part = props.get("part") or {}
        mid = part.get("messageID")
        # Skip the user's own prompt parts; only surface assistant output.
        if roles.get(mid) == "user":
            return
        ptype = part.get("type")
        state["last_activity"] = time.monotonic()
        if ptype == "text":
            ev_q.put({"type": "text", "sessionID": session_id, "part": part})
        elif ptype == "tool":
            # Only surface a tool part once it has a terminal state, matching
            # `opencode run --format json` (which emits tool_use on completion).
            st = (part.get("state") or {}).get("status")
            if st in ("completed", "error"):
                ev_q.put({"type": "tool_use", "sessionID": session_id, "part": part})
        elif ptype == "step-start":
            ev_q.put({"type": "step_start", "sessionID": session_id, "part": part})
        elif ptype == "step-finish":
            ev_q.put({"type": "step_finish", "sessionID": session_id, "part": part})
        return

    if t == "session.idle":
        # session.idle is opencode's turn-complete signal. Emit a run-format
        # step_finish(stop) so the child log carries turn boundaries (matching
        # `opencode run --format json`), then open the steering window.
        ev_q.put({"type": "step_finish", "sessionID": session_id,
                  "part": {"type": "step-finish", "reason": "stop"}})
        state["idle"] = True
        state["last_activity"] = time.monotonic()
        return

    if t == "session.error":
        err = props.get("error") or {}
        ev_q.put({"type": "error", "sessionID": session_id, "error": err})
        state["idle"] = True
        return


def drain_queue():
    alive = True
    while True:
        try:
            obj = ev_q.get_nowait()
        except queue.Empty:
            break
        if not emit(obj):
            alive = False
    return alive


# ----- steering fifo --------------------------------------------------------
# O_RDWR keeps a writer fd open on our side so the pipe never reports EOF as
# one-shot `cerebro steer` writers come and go, and never blocks on open.
fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
fbuf = b""
pending_steer = []
restart_pending = False
restart_diag = ""


def refill_fifo():
    global fbuf, restart_pending, restart_diag
    try:
        chunk = os.read(fd, 65536)
    except (BlockingIOError, OSError):
        return
    if not chunk:
        return
    fbuf += chunk
    while b"\n" in fbuf:
        raw, fbuf = fbuf.split(b"\n", 1)
        s = raw.decode("utf-8", "replace").strip()
        if s.startswith("S "):
            try:
                pending_steer.append(base64.b64decode(s[2:]).decode("utf-8", "replace"))
            except Exception:
                pass
        elif s.startswith("R "):
            try:
                restart_diag = base64.b64decode(s[2:]).decode("utf-8", "replace")
            except Exception:
                restart_diag = ""
            restart_pending = True


def mark_stalled(reason="stalled"):
    try:
        emit({"type": "step_finish", "sessionID": session_id,
              "part": {"type": "step-finish", "reason": "stalled", "is_error": True}})
    except Exception:
        pass
    marker = (child_log[:-6] if child_log.endswith(".jsonl") else child_log) + ".stalled"
    try:
        with open(marker, "w"):
            pass
    except OSError:
        pass


restart_path = (child_log[:-6] if child_log.endswith(".jsonl") else child_log) + ".restart"


def mark_restart(diag):
    try:
        emit({"type": "step_finish", "sessionID": session_id,
              "part": {"type": "step-finish", "reason": "restarted", "is_error": True}})
    except Exception:
        pass
    try:
        with open(restart_path, "w") as fh:
            fh.write(diag)
    except OSError:
        pass


# ----- drive the session ----------------------------------------------------
initial_prompt = sys.stdin.read()

reader = threading.Thread(target=sse_loop, daemon=True)
reader.start()
# Give the SSE subscription a moment to attach before the first prompt so we
# don't miss early parts.
time.sleep(0.4)

if not (200 <= send_prompt(initial_prompt) < 300):
    log_err("pair_pump: initial prompt was not accepted by opencode serve; "
            "no events will follow (see the HTTP error above). Aborting.")
    state["stop"] = True
    sys.exit(1)

idle_deadline = None
last_health_probe = time.monotonic()
health_fails = 0

while True:
    refill_fifo()
    if restart_pending:
        abort_session()
        state["stop"] = True
        drain_queue()
        mark_restart(restart_diag)
        sys.exit(0)

    # The server died and isn't coming back: reap fast rather than waiting out
    # the long stall timeout on an unreachable session.
    if state["serve_dead"]:
        state["stop"] = True
        drain_queue()
        mark_stalled("serve_unreachable")
        sys.exit(0)

    if not drain_queue():
        state["stop"] = True
        abort_session()
        sys.exit(0)

    if state["idle"]:
        if idle_deadline is None:
            idle_deadline = time.monotonic() + idle_grace
        if pending_steer:
            msg = pending_steer.pop(0)
            # Clear idle BEFORE sending: send_prompt is synchronous, and the
            # server can emit the steered turn's session.idle before it returns.
            # If we cleared idle after, the SSE thread's idle=True for the new
            # turn would be clobbered and the pump would never finish.
            state["idle"] = False
            idle_deadline = None
            state["last_activity"] = time.monotonic()
            send_prompt(msg)
            try:
                with open(steer_path, "a") as sf:
                    sf.write("- " + msg.replace("\n", "\n  ") + "\n")
            except OSError:
                pass
        elif time.monotonic() >= idle_deadline:
            state["stop"] = True
            sys.exit(0)
    else:
        silence = time.monotonic() - state["last_activity"]
        # When the stream has been quiet for a few seconds, actively probe the
        # server. If it is unreachable (died), reap fast instead of waiting out
        # the full stall window on a corpse.
        if silence >= 3 and (time.monotonic() - last_health_probe) >= 2:
            last_health_probe = time.monotonic()
            if not serve_alive():
                health_fails += 1
                if health_fails >= 2:
                    state["stop"] = True
                    drain_queue()
                    mark_stalled("serve_unreachable")
                    sys.exit(0)
            else:
                health_fails = 0
        if silence >= stall_busy_secs:
            abort_session()
            state["stop"] = True
            drain_queue()
            mark_stalled("quiet")
            sys.exit(0)

    time.sleep(0.3)
