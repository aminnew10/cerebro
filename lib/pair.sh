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
# (the file live steering is recorded to, folded back by pair_report),
# PAIR_IDLE (seconds of quiet after a turn before the child finishes), PAIR_PGID
# (the file the launcher writes the child's process-group id to), PAIR_STALL
# (seconds of frozen child log before the turn is declared stalled) and
# PAIR_LAUNCH (the exec_setsid shim that puts the child in its own group). On a
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
  # PAIR_IDLE   : quiet window after a turn before the child finishes.
  # PAIR_STALL  : AGGRESSIVE silent-watchdog threshold. The watchdog only sees
  #               child-log growth, so a SILENT long command (docker compose up
  #               -d --build, a full test suite, a big compile/clone) looks
  #               identical to a true hang and -- with the auto-restart below --
  #               can be killed+resumed repeatedly. RAISE CEREBRO_PAIR_STALL
  #               (e.g. 900) for build/test-heavy runs.
  # PAIR_STALL_RETRIES / PAIR_STALL_BACKOFF : bound and pace the auto-restart
  #               (default 2 relaunches; backoff base*2^(n-1), base 5s).
  PAIR_IDLE="${CEREBRO_PAIR_IDLE:-60}"
  PAIR_PGID="${child_log%.jsonl}.pgid"
  PAIR_STALL="${CEREBRO_PAIR_STALL:-90}"
  PAIR_LAUNCH=(python3 "$CEREBRO_LIB_DIR/python/exec_setsid.py" "$PAIR_PGID")
  : > "$PAIR_STEER"
  rm -f "$PAIR_FIFO" "$PAIR_PGID"
  mkfifo "$PAIR_FIFO" || die "pair: cannot create steering pipe at $PAIR_FIFO"
  pair_banner "$role" "$PAIR_SID" "$label" "$PAIR_FIFO"
}

# pair_cleanup <pair> -- remove the steering pipe and the pgid file once the
# child has exited. The `.stalled` sidecar is intentionally left in place: it is
# consumed by the auto-restart wrapper, which clears it itself before each
# relaunch and on give-up. pair_cleanup runs after every pipeline (including
# each stall relaunch), so it must NOT delete the marker.
pair_cleanup() {
  (( $1 )) || return 0
  [[ -n "${PAIR_FIFO:-}" ]] && rm -f "$PAIR_FIFO"
  [[ -n "${PAIR_PGID:-}" ]] && rm -f "$PAIR_PGID"
}

# --- stall-restart helpers (consumed by each --pair command's launch loop) ---

# pair_stall_marker <child_log> -- path of the pump's authoritative stall sidecar.
pair_stall_marker() { printf '%s' "${1%.jsonl}.stalled"; }

# pair_stalled <child_log> -- true iff the pump flagged this child as stalled.
pair_stalled() { [[ -e "$(pair_stall_marker "$1")" ]]; }

# pair_stall_clear <child_log> -- consume (remove) the stall marker.
pair_stall_clear() { rm -f "$(pair_stall_marker "$1")"; }

# pair_stall_backoff <attempt> -- wait CEREBRO_PAIR_STALL_BACKOFF * 2^(attempt-1)
# s (attempt 1 -> base*1, attempt 2 -> base*2, ...). Logs the chosen delay.
pair_stall_backoff() {
  # Bind n and base on their own lines first: a `$((...))` that references them
  # in the SAME `local` statement would expand before they are assigned, which
  # under `set -u` reads them as unbound and aborts.
  local n="$1"
  local base="${CEREBRO_PAIR_STALL_BACKOFF:-5}"
  local d=$(( base * (1 << (n - 1)) ))
  log_event "pair_stall_restart" "attempt=$n backoff=${d}s"
  if (( d > 0 )); then sleep "$d"; fi
}

# pair_feed <pair> <fifo> <steer> <child_log> <idle_grace> <pgid_file> <stall>
# -- stdin carries the initial prompt. Unpaired: pass it through unchanged as
# claude -p text input (the extra args are ignored). Paired: hand it to the
# stream-json input pump (lib/python/pair_pump.py), which emits the prompt as
# the first user message, then after each turn holds a steering window open on
# the named pipe before a quiet window finishes the child -- and reaps the
# child's group (via <pgid_file>) if its log freezes past <stall> seconds.
pair_feed() {
  local pair="$1" fifo="$2" steer="$3" child_log="$4" grace="$5" pgid="$6" stall="$7"
  if (( pair )); then
    python3 "$CEREBRO_LIB_DIR/python/pair_pump.py" \
      "$fifo" "$steer" "$child_log" "$grace" "$pgid" "$stall"
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

