# cerebro lib: commands/session
# subcommands: launch / --resume / list
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro (launch new session) ----------------------------

# Global preference files (span every session under $CEREBRO_HOME).
learnings_file()         { printf '%s\n' "$CEREBRO_HOME/learnings.md"; }
pending_learnings_file() { printf '%s\n' "$CEREBRO_HOME/pending-learnings.md"; }

# Build the orchestrator's full system prompt: the static catalog plus, when
# present, the user's learned preferences. learnings.md is kept small (capped
# by cmd_learn_set) so it fits in the system message; a whitespace-only file
# is treated as empty. Echoed on stdout.
orchestrator_append_prompt() {
  local base; base="$(cat "$CEREBRO_HOME/system-prompt.md")"
  local lf body=""
  lf="$(learnings_file)"
  if [[ -s "$lf" ]]; then
    body="$(cat "$lf")"
    [[ -n "${body//[[:space:]]/}" ]] || body=""
  fi
  if [[ -n "$body" ]]; then
    printf '%s\n\n# Learned preferences\n\nDurable preferences cerebro has learned from this user across past sessions. Honor them by default in every plan, execute, review, and apply-review decision unless the user overrides in the moment.\n\n%s\n' "$base" "$body"
  else
    printf '%s\n' "$base"
  fi
}

cmd_launch() {
  require_interactive
  require_deps
  materialise_home

  local sid sess_dir ts
  sid="$(mint_uuid)"
  sess_dir="$CEREBRO_HOME/sessions/$sid"
  mkdir -p "$sess_dir/plans" "$sess_dir/children"
  : > "$sess_dir/transcript.jsonl"
  ts="$(ts_iso)"
  write_metadata_new "$sess_dir" "$sid" "$ts"

  export CEREBRO_SESSION_ID="$sid"
  export CEREBRO_SESSION_DIR="$sess_dir"
  export CEREBRO_HOME

  CEREBRO_SESSION_DIR="$sess_dir" log_event "session_created"

  say "cerebro: starting session $sid"
  cd "$CEREBRO_HOME" || die "cd to $CEREBRO_HOME failed"
  exec claude \
    --session-id "$sid" \
    --append-system-prompt "$(orchestrator_append_prompt)" \
    --allowedTools "Bash(cerebro:*) Read Grep Glob WebSearch WebFetch mcp__playwright__*"
}

# Build the observer session's system prompt: the full orchestrator prompt
# (so it understands what audit/execute/review children do) plus the
# observe-mode overlay that narrows it to watching and steering. When a target
# id is given, point it at that session by default. Echoed on stdout.
observer_append_prompt() {
  local target="${1:-}"
  local base mode
  base="$(orchestrator_append_prompt)"
  mode="$(cerebro_observe_mode_prompt)"
  if [[ -n "$target" ]]; then
    printf '%s\n\n%s\n\nThe user launched this observer to watch session `%s`. Begin by running `cerebro observe %s` and narrating what you see; keep looping until its children are done or the user stops you.\n' \
      "$base" "$mode" "$target" "$target"
  else
    printf '%s\n\n%s\n' "$base" "$mode"
  fi
}

# ----- subcommand: cerebro --observe [<id>] --------------------------------

# Block until there is something to observe: another session with live paired
# children (a named target's, or -- with no target -- any other session's).
# Polls observe_pump's cheap probe mode, sleeping CEREBRO_OBSERVE_POLL seconds
# between tries, so the observer chat opens onto live activity instead of an
# immediate "nothing to observe". The user can Ctrl-C to bail. No python3 (or
# no sessions root) -> proceed immediately and let the session sort it out.
observer_wait_until_observable() {
  local target="${1:-}"
  command -v python3 >/dev/null 2>&1 || return 0
  python3 "$CEREBRO_LIB_DIR/python/observe_pump.py" \
    "$CEREBRO_HOME/sessions" "$target" "" "" 0 0 probe >/dev/null 2>&1 && return 0
  local who="paired children"
  [[ -n "$target" ]] && who="session $target's paired children"
  say "cerebro: waiting for $who to observe... (Ctrl-C to cancel)"
  while ! python3 "$CEREBRO_LIB_DIR/python/observe_pump.py" \
      "$CEREBRO_HOME/sessions" "$target" "" "" 0 0 probe >/dev/null 2>&1; do
    sleep "${CEREBRO_OBSERVE_POLL:-2}"
  done
}

# Launch a native interactive `claude` chat dedicated to observing and
# steering another cerebro session's live paired children. Same session
# plumbing as cmd_launch, but the system prompt is the observe-mode overlay
# and the tool allow-list is narrowed to observe + steer + read-only commands,
# so this session can never make direct repo changes. Optional first arg is
# the target session id to watch by default.
cmd_launch_observer() {
  require_interactive
  require_deps
  materialise_home

  local target="${1:-}"
  # Don't open the chat until something is observable; poll until it is. Done
  # before minting the session so a Ctrl-C here leaves no orphan session dir.
  observer_wait_until_observable "$target"

  local sid sess_dir ts
  sid="$(mint_uuid)"
  sess_dir="$CEREBRO_HOME/sessions/$sid"
  mkdir -p "$sess_dir/plans" "$sess_dir/children"
  : > "$sess_dir/transcript.jsonl"
  ts="$(ts_iso)"
  write_metadata_new "$sess_dir" "$sid" "$ts"

  export CEREBRO_SESSION_ID="$sid"
  export CEREBRO_SESSION_DIR="$sess_dir"
  export CEREBRO_HOME

  CEREBRO_SESSION_DIR="$sess_dir" log_event "session_created" "observer"

  say "cerebro: starting observer session $sid${target:+ (watching $target)}"
  cd "$CEREBRO_HOME" || die "cd to $CEREBRO_HOME failed"

  # When a target is given, seed an interactive first turn so the observer
  # starts narrating immediately instead of waiting for the user to type.
  # A positional prompt without -p keeps the session interactive; it just
  # submits as the first user message. The prompt MUST come before the
  # variadic --allowedTools (<tools...>), which would otherwise swallow it
  # as another tool token. With no target we stay fully interactive so the
  # user can pick which session to watch.
  local allowed="Bash(cerebro observe:*) Bash(cerebro steer:*) Bash(cerebro restart:*) Bash(cerebro status:*) Bash(cerebro list:*) Bash(cerebro recall:*) Bash(cerebro spec:*) Bash(cerebro learnings:*) Read Grep Glob WebSearch WebFetch mcp__playwright__*"
  if [[ -n "$target" ]]; then
    exec claude \
      --session-id "$sid" \
      --append-system-prompt "$(observer_append_prompt "$target")" \
      "Start observing session $target now: run \`cerebro observe $target\`, narrate what you see, and keep looping until its children are done or I stop you." \
      --allowedTools "$allowed"
  else
    exec claude \
      --session-id "$sid" \
      --append-system-prompt "$(observer_append_prompt "$target")" \
      --allowedTools "$allowed"
  fi
}

# ----- subcommand: cerebro --resume [<id>] ---------------------------------

cmd_resume() {
  require_interactive
  require_deps
  materialise_home

  local id="${1:-}"
  export CEREBRO_HOME

  if [[ -n "$id" ]]; then
    local sess_dir="$CEREBRO_HOME/sessions/$id"
    [[ -d "$sess_dir" ]] || die "no such session: $id"
    touch_metadata "$sess_dir" "$(ts_iso)"
    export CEREBRO_SESSION_ID="$id"
    export CEREBRO_SESSION_DIR="$sess_dir"
    say "cerebro: resuming session $id"
  else
    # Bare resume: claude shows its own picker. The hook will write the
    # current-session symlink as soon as the user submits their first
    # prompt, and orchestrator subcommands fall back to that.
    say "cerebro: resuming via claude's picker"
  fi

  cd "$CEREBRO_HOME" || die "cd to $CEREBRO_HOME failed"
  if [[ -n "$id" ]]; then
    exec claude \
      --resume "$id" \
      --append-system-prompt "$(orchestrator_append_prompt)" \
      --allowedTools "Bash(cerebro:*) Read Grep Glob WebSearch WebFetch mcp__playwright__*"
  else
    exec claude \
      --resume \
      --append-system-prompt "$(orchestrator_append_prompt)" \
      --allowedTools "Bash(cerebro:*) Read Grep Glob WebSearch WebFetch mcp__playwright__*"
  fi
}

# ----- subcommand: cerebro list --------------------------------------------

cmd_list() {
  require_interactive
  if [[ ! -d "$CEREBRO_HOME/sessions" ]] || \
     [[ -z "$(ls -A "$CEREBRO_HOME/sessions" 2>/dev/null)" ]]; then
    echo "cerebro: no sessions yet"
    return 0
  fi
  # Sort by metadata.last_touched, newest first.
  python3 "$CEREBRO_LIB_DIR/python/list_sessions.py" "$CEREBRO_HOME/sessions"
}

