# cerebro lib: pair
# pair-programming mode: watch + steer a live child session
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- pair-programming mode -----------------------------------------------
# `--pair` on a claude child (plan / execute / apply-review / doc-write) lets the
# developer WATCH the live session and STEER it. cerebro drives the child through
# claude's stream-json input (`--input-format stream-json`): it feeds the initial
# prompt as the first user message, then after each turn waits a short window for
# steering injected over a named pipe. Another cerebro session watches this one's
# paired children with `cerebro observe <this-session-id>` (see cmd_observe);
# `cerebro steer "<message>"` is a one-shot inject -- it writes one instruction to
# the child and returns at once (no attach, no lock). The child runs to completion;
# each turn opens a brief steering window (CEREBRO_PAIR_IDLE) and a quiet window
# finishes it. Steering is recorded as it is injected and folded back so the
# orchestrator can reconcile it against the spec.

# pair_label <role> <repo> [branch] -- a stable, human-readable session name
# for the paired child (shown in cerebro's connect banner).
pair_label() {
  local role="$1" repo="$2" branch="${3:-}"
  printf 'cerebro:%s:%s%s' "$role" "$(basename "$repo")" "${branch:+:$branch}"
}

# pair_banner <role> <sid> <label> <fifo> -- tell the developer how to attach to
# the live child. Goes to stderr so it never pollutes the stdout child-log path
# contract.
pair_banner() {
  local role="$1" sid="$2" label="$3" fifo="$4"
  {
    printf 'cerebro: PAIR MODE -- watch this %s session live and steer it.\n' "$role"
    printf '  session : %s (id %s)\n' "$label" "$sid"
    printf '  observe : from ANOTHER cerebro, ask it to: observe %s\n' "${CEREBRO_SESSION_ID:-<this-session-id>}"
    printf '            (it narrates every live paired child of this session)\n'
    printf '  steer   : cerebro steer "<message>"   (inject one instruction; returns at once)\n'
    printf '            if several paired sessions run at once: cerebro steer %s "<message>"\n' "$fifo"
    printf '  the child runs to completion; it waits a short window after each turn for\n'
    printf '  steering, so steer within that window to keep it open and redirect it.\n'
    printf '  your steering goes straight into the child; it never enters the orchestrator chat.\n'
  } >&2
}

# pair_begin <role> <repo> <branch> <child_log> [resume-id] -- prepare a fresh
# or resumed paired child. Sets caller-scoped: PAIR_SID (session id), PAIR_OPTS
# (extra claude flags -- stream-json input, plus a pinned --session-id for a
# fresh run), PAIR_FIFO (the named pipe `cerebro steer` writes to), PAIR_STEER
# (the file live steering is recorded to, folded back by pair_report) and
# PAIR_IDLE (seconds of quiet after a turn before the child finishes). On a
# resume the stored id is reused and the caller's --resume sets the session id.
pair_begin() {
  local role="$1" repo="$2" branch="${3:-}" child_log="$4" resume="${5:-}"
  local label; label="$(pair_label "$role" "$repo" "$branch")"
  if [[ -n "$resume" ]]; then
    PAIR_SID="$resume"
    PAIR_OPTS=(--input-format stream-json)
  else
    PAIR_SID="$(mint_uuid)"
    PAIR_OPTS=(--session-id "$PAIR_SID" --input-format stream-json)
  fi
  PAIR_STEER="${child_log%.jsonl}.steering.md"
  PAIR_FIFO="${child_log%.jsonl}.steer.fifo"
  PAIR_IDLE="${CEREBRO_PAIR_IDLE:-60}"
  : > "$PAIR_STEER"
  rm -f "$PAIR_FIFO"
  mkfifo "$PAIR_FIFO" || die "pair: cannot create steering pipe at $PAIR_FIFO"
  pair_banner "$role" "$PAIR_SID" "$label" "$PAIR_FIFO"
}

# pair_cleanup <pair> -- remove the steering pipe and presence lock once the
# child has exited.
pair_cleanup() {
  (( $1 )) || return 0
  [[ -n "${PAIR_FIFO:-}" ]] && rm -f "$PAIR_FIFO"
}

# The input-pump for a paired child. stdin carries the initial prompt; argv is
# <fifo> <steer_path> <child_log> <idle_grace>. It emits the prompt as the first
# stream-json user message, then watches <child_log> for the `result` event that
# ends each turn. After each turn it waits up to <idle_grace> seconds for a
# one-shot `cerebro steer` message to arrive over <fifo> ("S <base64>" per
# message); each message is forwarded as the next user turn and appended to
# <steer_path>, and resets the window. A quiet window closes claude'\''s stdin so
# the child finishes. The child therefore runs to completion on its own, with a
# short steering window after every turn -- no developer needs to stay attached.
PY_PAIR_PUMP='
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
    # bounded by cerebro'\''s outer timeout, not here.
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
'

# pair_feed <pair> <fifo> <steer> <child_log> <idle_grace> -- stdin carries the
# initial prompt. Unpaired: pass it through unchanged as claude -p text input.
# Paired: hand it to the stream-json input pump above.
pair_feed() {
  local pair="$1" fifo="$2" steer="$3" child_log="$4" grace="$5"
  if (( pair )); then
    python3 -c "$PY_PAIR_PUMP" "$fifo" "$steer" "$child_log" "$grace"
  else
    cat
  fi
}

# pair_report <pair> <child_log> -- after a paired child exits, fold the live
# steering it received (recorded to the .steering.md beside its log as each
# message was injected) back onto stdout as a compact bullet block for the
# orchestrator to reconcile against the spec. A no-op when unpaired or when no
# steering was sent.
pair_report() {
  local pair="$1" child_log="$2"
  (( pair )) || return 0
  local steer_path="${child_log%.jsonl}.steering.md" n=0
  [[ -s "$steer_path" ]] && n="$(grep -c '^- ' "$steer_path" 2>/dev/null || printf 0)"
  if [[ "${n:-0}" -gt 0 ]]; then
    log_event "pair_steering" "n=$n path=$steer_path"
    printf '=== PAIR STEERING (%s message(s), applied live) ===\n' "$n"
    cat "$steer_path"
    printf '=== END PAIR STEERING (file: %s) ===\n' "$steer_path"
    say "cerebro: folded $n live steering message(s) from the paired session -> $steer_path"
  else
    say "cerebro: pair mode -- no steering was sent during the paired session"
  fi
}

