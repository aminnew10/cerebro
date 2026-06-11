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
# (so it understands what plan/execute/review children do) plus the
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
  exec claude \
    --session-id "$sid" \
    --append-system-prompt "$(observer_append_prompt "$target")" \
    --allowedTools "Bash(cerebro observe:*) Bash(cerebro steer:*) Bash(cerebro status:*) Bash(cerebro list:*) Bash(cerebro recall:*) Bash(cerebro spec:*) Bash(cerebro learnings:*) Read Grep Glob WebSearch WebFetch mcp__playwright__*"
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

