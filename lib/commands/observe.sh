# cerebro lib: commands/observe
# subcommand: observe (cross-session live monitor)
# Sourced by bin/cerebro; not meant to be executed directly.


# ----- subcommand: cerebro observe [<session-id>] --------------------------
# Live monitor: look over the shoulder of ANOTHER cerebro session's paired
# children. The optional <session-id> names that orchestrator session (NOT a
# child); with none, the most recently active other session that has live
# paired children is chosen. It tails that session's own transcript (an
# "orchestrator session" track) AND every live paired child of that session at
# once and returns ONE batch of new activity plus a STATUS footer
# (active = call again, done = no live children left), then exits. The
# orchestrator narrates the gist and the important decisions, then calls again
# until done -- a running commentary inside the same chat. A per-target cursor
# under the observer's own session dir advances each call so nothing repeats.
# Read-only: it only tails the children's logs; steering stays the separate,
# explicit `cerebro steer <steer-pipe> "<message>"`.
cmd_observe() {
  require_session
  command -v python3 >/dev/null 2>&1 || die "observe: missing required command on PATH: python3"
  local target_id="${1:-}"
  [[ -d "$CEREBRO_HOME/sessions" ]] || die "observe: no sessions yet"
  python3 "$CEREBRO_LIB_DIR/python/observe_pump.py" \
    "$CEREBRO_HOME/sessions" "$target_id" "$CEREBRO_SESSION_ID" \
    "$CEREBRO_SESSION_DIR/observe-state" \
    "${CEREBRO_OBSERVE_WINDOW:-90}" "${CEREBRO_OBSERVE_QUIET:-12}"
}

