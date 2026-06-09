# cerebro lib: session-store
# session metadata + child-agent session store
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- session metadata -----------------------------------------------------

write_metadata_new() {
  local sess_dir="$1" sid="$2" ts="$3"
  jq -n --arg sid "$sid" --arg ts "$ts" \
    '{claude_session_id:$sid, created_at:$ts, last_touched:$ts}' \
    > "$sess_dir/metadata.json"
}

touch_metadata() {
  local sess_dir="$1" ts="$2" tmp
  [[ -f "$sess_dir/metadata.json" ]] || return 0
  tmp="$(mktemp)" || return 0
  jq --arg ts "$ts" '.last_touched = $ts' "$sess_dir/metadata.json" \
    > "$tmp" 2>/dev/null && mv "$tmp" "$sess_dir/metadata.json" || rm -f "$tmp"
}

# ----- child agent session store -------------------------------------------
# A small per-session JSON map of provider conversation ids + in-flight state
# so repeated execute/review/apply-review/doc-write calls on the same line of
# work resume the same underlying provider conversation -- and so a child that
# was interrupted mid-run can be resumed on continue rather than redone. Keyed
# by child_key (repo+role+branch). Each entry carries {id, provider, role,
# repo, branch, log, status, started_at, updated_at}; status is "running"
# until the child cleanly finishes (then "done"). The file is created lazily
# on the first child_store_begin and lives alongside spec.md / metadata.json,
# so it survives context compaction.

child_sessions_file() { printf '%s\n' "$CEREBRO_SESSION_DIR/child-sessions.json"; }

# child_key <repo> <role> <branch> -- stable short hash identifying one line
# of work. role is execute|review so an execute conversation and a review
# conversation on the same branch stay distinct.
child_key() {
  local repo="$1" role="$2" branch="${3:-default}"
  printf '%s\0%s\0%s' "$repo" "$role" "$branch" | python3 -c 'import sys,hashlib; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest())' | cut -c1-16
}

# child_store <op> [args...] -- the single entry point for every mutation
# and query of child-sessions.json. All access goes through one fcntl-locked
# python process (PY_CHILD_STORE) so concurrent --pair children that each
# persist their own id at startup cannot clobber the whole-file rewrite.
child_store() { python3 -c "$PY_CHILD_STORE" "$(child_sessions_file)" "$@"; }

# child_session_get <key> -- echo the stored provider id for <key>, or
# nothing when the file or entry is absent.
child_session_get() {
  local f; f="$(child_sessions_file)"
  [[ -f "$f" ]] || return 0
  child_store get "$1"
}

# child_session_fresh <key> -- succeed when <key> has a stored entry whose
# updated_at is within CEREBRO_CHILD_SESSION_TTL seconds (default 24h). A
# missing/unparseable timestamp or an over-TTL entry is treated as stale.
child_session_fresh() {
  local f; f="$(child_sessions_file)"
  [[ -f "$f" ]] || return 1
  child_store fresh "$1" "${CEREBRO_CHILD_SESSION_TTL:-86400}"
}

# child_store_begin <key> <provider> <role> <repo> <branch> <log> -- mark a
# child as in-flight (status=running) the moment before it launches, so an
# interrupt mid-run leaves a discoverable, resumable record. Any id already
# stored for <key> (from a prior run we are resuming) is preserved.
child_store_begin() {
  [[ -n "${1:-}" ]] || return 0
  local f; f="$(child_sessions_file)"
  [[ -f "$f" ]] || printf '{}\n' > "$f"
  child_store begin "$1" "$2" "$3" "$4" "$5" "$6" "$(ts_iso)"
}

# child_store_done <key> -- mark a child cleanly finished (status=done). An
# entry left at status=running is treated as interrupted/incomplete and is
# surfaced by `cerebro status` for the orchestrator to resume on continue.
child_store_done() {
  [[ -n "${1:-}" ]] || return 0
  child_store done "$1" "$(ts_iso)"
}

# child_store_list_running -- emit a TSV row
# (key, role, repo, branch, log, started_at) for every still-fresh child left
# at status=running (interrupted or failed before it could mark itself done).
child_store_list_running() {
  local f; f="$(child_sessions_file)"
  [[ -f "$f" ]] || return 0
  child_store list-running "${CEREBRO_CHILD_SESSION_TTL:-86400}"
}

