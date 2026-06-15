# cerebro lib: commands/status
# subcommand: status
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro status ------------------------------------------

cmd_status() {
  require_session
  echo "session: $CEREBRO_SESSION_ID"
  echo "dir:     $CEREBRO_SESSION_DIR"
  echo
  local spec_f spec_h
  spec_f="$CEREBRO_SESSION_DIR/spec.md"
  spec_h="$CEREBRO_SESSION_DIR/spec-history.jsonl"
  if [[ -s "$spec_f" ]]; then
    local sv=0
    [[ -f "$spec_h" ]] && sv="$(grep -c '' "$spec_h" 2>/dev/null || printf 0)"
    echo "session spec: present ($spec_f; ${sv} version(s) in history)"
  else
    echo "session spec: (none)"
  fi
  echo
  echo "plans:"
  if [[ -d "$CEREBRO_SESSION_DIR/plans" ]] && \
     [[ -n "$(ls -A "$CEREBRO_SESSION_DIR/plans" 2>/dev/null)" ]]; then
    (cd "$CEREBRO_SESSION_DIR/plans" && ls -1t *.md 2>/dev/null | sed 's/^/  /')
  else
    echo "  (none)"
  fi
  echo
  echo "children (most recent 5):"
  if [[ -d "$CEREBRO_SESSION_DIR/children" ]] && \
     [[ -n "$(ls -A "$CEREBRO_SESSION_DIR/children" 2>/dev/null)" ]]; then
    (cd "$CEREBRO_SESSION_DIR/children" && ls -1t 2>/dev/null | head -5 | sed 's/^/  /')
  else
    echo "  (none)"
  fi
  echo
  # In-flight children: any keyed child (execute / review / apply-review /
  # doc-write) left at status=running was interrupted or failed before it
  # could finish. Its provider conversation id is already stored, so
  # re-issuing the SAME command resumes the half-done work instead of redoing
  # it. The orchestrator checks this on continue (see the system prompt).
  echo "interrupted / in-flight children (incomplete -- resume on continue):"
  local _inflight; _inflight="$(child_store_list_running)"
  if [[ -n "$_inflight" ]]; then
    printf '%s\n' "$_inflight" | while IFS=$'\t' read -r _k _role _repo _branch _log _started; do
      printf '  [%s] %s  repo=%s  branch=%s\n' "$_role" "$_started" "$_repo" "${_branch:-?}"
      printf '      log: %s\n' "$_log"
      printf '      resume: re-issue the same `cerebro %s %s ...` command -- cerebro --resumes this child automatically.\n' "$_role" "$_repo"
    done
  else
    echo "  (none)"
  fi
  echo
  local last_review
  last_review="$(ls -1t "$CEREBRO_SESSION_DIR"/children/review-*.md 2>/dev/null | head -1)"
  if [[ -n "$last_review" ]]; then
    echo "last review: $last_review"
  else
    echo "last review: (none)"
  fi
  echo
  local lf pf
  lf="$(learnings_file)"; pf="$(pending_learnings_file)"
  if [[ -s "$lf" ]]; then
    echo "learnings: active ($lf)"
  else
    echo "learnings: (none)"
  fi
  if [[ -s "$pf" ]]; then
    local pc; pc="$(grep -c '^- \[' "$pf" 2>/dev/null || true)"
    echo "pending preference signals: ${pc:-0} ($pf)"
  fi
}

