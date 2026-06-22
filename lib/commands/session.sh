# cerebro lib: commands/session
# subcommands: launch / --resume / --observe / list
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro (launch new session) ----------------------------

# Global preference files (span every session under $CEREBRO_HOME).
learnings_file()         { printf '%s\n' "$CEREBRO_HOME/learnings.md"; }
pending_learnings_file() { printf '%s\n' "$CEREBRO_HOME/pending-learnings.md"; }

# User-owned harness overlays (global under $CEREBRO_HOME). Each overlay is a
# plain-markdown file the loaders APPEND onto a shipped prompt/grader, so a user
# can tune any prompt surface locally without forking -- the same user-owned
# pattern as learnings.md. materialise_home() never creates or clobbers them; an
# absent or whitespace-only overlay changes nothing.
overlays_dir() { printf '%s\n' "$CEREBRO_HOME/overlays"; }
overlay_file() { printf '%s\n' "$(overlays_dir)/$1.md"; }   # $1 = target
overlay_body() {   # $1=target; echoes body only if present + non-whitespace
  local f; f="$(overlay_file "$1")"
  [[ -s "$f" ]] || return 0
  local b; b="$(cat "$f")"
  [[ -n "${b//[[:space:]]/}" ]] && printf '%s' "$b"
}

# Build the orchestrator's full system prompt: the static catalog plus, when
# present, the user's learned preferences. learnings.md is kept small (capped
# by cmd_learn_set) so it fits in the system message; a whitespace-only file
# is treated as empty. Echoed on stdout.
orchestrator_append_prompt() {
  local base; base="$(cerebro_system_prompt)"
  local lf body=""
  lf="$(learnings_file)"
  if [[ -s "$lf" ]]; then
    body="$(cat "$lf")"
    [[ -n "${body//[[:space:]]/}" ]] || body=""
  fi
  if [[ -n "$body" ]]; then
    base="$(printf '%s\n\n# Learned preferences\n\nDurable preferences cerebro has learned from this user across past sessions. Honor them by default in every plan, execute, review, and apply-review decision unless the user overrides in the moment.\n\n%s' "$base" "$body")"
  fi
  local ov; ov="$(overlay_body system)"
  if [[ -n "$ov" ]]; then
    printf '%s\n\n# Local harness overlay\n\n%s\n' "$base" "$ov"
  else
    printf '%s\n' "$base"
  fi
}

# Write the orchestrator agent definition for this launch into the opencode
# config dir. It carries the composed system prompt (catalog + learnings) as its
# body and the read-only permission clamp in its frontmatter. Regenerated each
# launch so learned preferences stay current. Echoes the agent name.
write_orchestrator_agent() {
  local body; body="$(orchestrator_append_prompt)"
  write_if_changed "$CEREBRO_HOME/.opencode/agent/cerebro-orchestrator.md" \
    "$(orchestrator_agent_file "$body")"
  printf 'cerebro-orchestrator\n'
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

  local agent; agent="$(write_orchestrator_agent)"

  export CEREBRO_SESSION_ID="$sid"
  export CEREBRO_SESSION_DIR="$sess_dir"
  export CEREBRO_HOME

  CEREBRO_SESSION_DIR="$sess_dir" log_event "session_created"

  say "cerebro: starting session $sid"
  cd "$CEREBRO_HOME" || die "cd to $CEREBRO_HOME failed"
  # opencode assigns its own session id; the cerebro plugin records it into
  # metadata.json so `cerebro --resume` can reopen the same conversation. The
  # exported CEREBRO_SESSION_ID binds every `cerebro` subcommand the
  # orchestrator runs back to this session (opencode's bash tool inherits env).
  local model_opt=(); [[ -n "$CEREBRO_MODEL" ]] && model_opt=(--model "$CEREBRO_MODEL")
  local port; port="$(reserve_orchestrator_port)"
  say "cerebro: Web UI available at http://127.0.0.1:$port"
  exec "$CEREBRO_OPENCODE_CMD" --agent "$agent" "${model_opt[@]}" --port "$port"
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

# Write the observer agent definition for this launch. Echoes the agent name.
write_observer_agent() {
  local target="${1:-}" body
  body="$(observer_append_prompt "$target")"
  write_if_changed "$CEREBRO_HOME/.opencode/agent/cerebro-observer.md" \
    "$(observer_agent_file "$body")"
  printf 'cerebro-observer\n'
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

# Launch a native interactive `opencode` chat dedicated to observing and
# steering another cerebro session's live paired children. Same session
# plumbing as cmd_launch, but the agent is the observe-mode one whose tools are
# narrowed to observe + steer + read-only commands, so this session can never
# make direct repo changes. Optional first arg is the target session id to watch
# by default.
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

  local agent; agent="$(write_observer_agent "$target")"

  export CEREBRO_SESSION_ID="$sid"
  export CEREBRO_SESSION_DIR="$sess_dir"
  export CEREBRO_HOME

  CEREBRO_SESSION_DIR="$sess_dir" log_event "session_created" "observer"

  say "cerebro: starting observer session $sid${target:+ (watching $target)}"
  cd "$CEREBRO_HOME" || die "cd to $CEREBRO_HOME failed"

  # When a target is given, seed an interactive first turn (via --prompt) so the
  # observer starts narrating immediately instead of waiting for the user to
  # type. With no target we stay fully interactive so the user can pick which
  # session to watch.
  local model_opt=(); [[ -n "$CEREBRO_MODEL" ]] && model_opt=(--model "$CEREBRO_MODEL")
  local port; port="$(reserve_orchestrator_port)"
  say "cerebro: Web UI available at http://127.0.0.1:$port"
  if [[ -n "$target" ]]; then
    exec "$CEREBRO_OPENCODE_CMD" --agent "$agent" "${model_opt[@]}" --port "$port" \
      --prompt "Start observing session $target now: run \`cerebro observe $target\`, narrate what you see, and keep looping until its children are done or I stop you."
  else
    exec "$CEREBRO_OPENCODE_CMD" --agent "$agent" "${model_opt[@]}" --port "$port"
  fi
}

# ----- subcommand: cerebro --resume [<id>] ---------------------------------

cmd_resume() {
  require_interactive
  require_deps
  materialise_home

  local id="${1:-}"
  export CEREBRO_HOME

  # With no id, resume the most recently touched session (opencode has no
  # cross-session picker of its own, and cerebro now identifies sessions by its
  # own id rather than relying on a hook).
  if [[ -z "$id" ]]; then
    id="$(python3 "$CEREBRO_LIB_DIR/python/list_sessions.py" "$CEREBRO_HOME/sessions" --most-recent 2>/dev/null)"
    [[ -n "$id" ]] || die "no sessions to resume"
    say "cerebro: resuming most recent session $id"
  fi

  local sess_dir="$CEREBRO_HOME/sessions/$id"
  [[ -d "$sess_dir" ]] || die "no such session: $id"
  touch_metadata "$sess_dir" "$(ts_iso)"

  local agent; agent="$(write_orchestrator_agent)"

  export CEREBRO_SESSION_ID="$id"
  export CEREBRO_SESSION_DIR="$sess_dir"
  say "cerebro: resuming session $id"

  # Reopen the same opencode conversation when we captured its id at launch;
  # otherwise start a fresh opencode session in this same cerebro session dir
  # (cerebro state -- spec, plans, children -- persists regardless).
  local ocid=""
  [[ -f "$sess_dir/metadata.json" ]] && \
    ocid="$(jq -r '.opencode_session_id // empty' "$sess_dir/metadata.json" 2>/dev/null)"

  cd "$CEREBRO_HOME" || die "cd to $CEREBRO_HOME failed"
  local model_opt=(); [[ -n "$CEREBRO_MODEL" ]] && model_opt=(--model "$CEREBRO_MODEL")
  local port; port="$(reserve_orchestrator_port)"
  say "cerebro: Web UI available at http://127.0.0.1:$port"
  if [[ -n "$ocid" ]]; then
    exec "$CEREBRO_OPENCODE_CMD" --session "$ocid" --agent "$agent" "${model_opt[@]}" --port "$port"
  else
    warn "no stored opencode session id for $id; starting a fresh opencode conversation"
    exec "$CEREBRO_OPENCODE_CMD" --agent "$agent" "${model_opt[@]}" --port "$port"
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
