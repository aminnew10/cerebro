# cerebro lib: commands/improve
# subcommand: improve (hill-climbing trace analysis of the accumulated corpus)
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro improve <cerebro-repo> [--context "..."] --------
# The fourth loop: a read-only `opencode exec` mines cerebro's accumulated agent
# traces under $CEREBRO_HOME for problems that RECUR across runs and proposes
# the smallest fixes, routed to local overlays / learnings (GitHub-free) or --
# for whoever maintains the source -- an upstream PR. cwd is the cerebro repo so
# opencode reads/cites the real harness files; the read-only sandbox still reads
# the trace corpus under $CEREBRO_HOME. ANALYSE/PROPOSE only: findings go to a
# fixed improvements/improve.md (re-run overwrites) ending with a HILL CLIMB
# verdict line. Nothing here rewrites the harness.

cmd_improve() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local context=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) shift; context="${1:-}"; shift || true ;;
      *) die "improve: unknown arg: $1" ;;
    esac
  done
  [[ -n "$repo" ]] \
    || die "usage: cerebro improve <cerebro-repo-abs-path> [--context \"<focus>\"]"
  [[ "$repo" = /* ]] || die "improve: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "improve: repo not a directory: $repo"

  local imp_dir="$CEREBRO_SESSION_DIR/improvements"
  mkdir -p "$imp_dir"
  local out_path="$imp_dir/improve.md"
  local err_path="${out_path%.md}.err"

  # Child-session continuity is only for an interrupted/incomplete run. A
  # cleanly finished run gets marked done; re-running starts fresh.
  local store_file; store_file="$(child_sessions_file)"
  local ckey prior=""
  ckey="$(child_key "$repo" improve improve)"
  if prior="$(child_session_get "$ckey")" && [[ -n "$prior" ]] && child_session_running_fresh "$ckey"; then
    :
  else
    prior=""
  fi

  say "cerebro: mining traces under $CEREBRO_HOME against $repo -> $out_path"
  log_event "improve_started" "repo=$repo out=$out_path resume=${prior:-none}"

  local improve_prompt
  improve_prompt="$(cerebro_improve_prompt)

The cerebro trace corpus to analyse lives under: $CEREBRO_HOME
  sessions/*/children/*.jsonl   - agent trajectories (model + tool calls)
  sessions/*/transcript.jsonl   - user prompts + milestones
  sessions/*/audits/*.md, sessions/*/children/opencode-*.md - grader feedback
  pending-learnings.md, learnings.md, overlays/*.md - applied prefs/overlays"

  if [[ -n "$context" ]]; then
    improve_prompt+="

Focus from the orchestrator (where to concentrate the analysis):

<context>
$context
</context>"
  fi

  # Run with --json so opencode streams JSONL events on stdout (the only place it
  # exposes the resumable thread_id), and -o writes the human-readable findings
  # to out_path. parse_stream.py persists the thread_id the instant opencode
  # emits it, so an interrupt mid-run leaves a resumable record. cwd is the
  # repo so opencode cites the real harness files; the read-only sandbox still
  # reads the traces under $CEREBRO_HOME.
  local opencode_opts=(exec --json --sandbox read-only --skip-git-repo-check \
                    --cd "$repo" -o "$out_path")
  [[ -n "$CEREBRO_REVIEW_MODEL" ]] && opencode_opts+=(--model "$CEREBRO_REVIEW_MODEL")
  local json_path; json_path="$(mktemp)"

  local rc run_args
  if [[ -n "$prior" ]]; then
    run_args=("${opencode_opts[@]}" resume "$prior" "$improve_prompt")
  else
    run_args=("${opencode_opts[@]}" "$improve_prompt")
  fi
  child_store_begin "$ckey" opencode improve "$repo" improve "$out_path" "${prior:+preserve-id}"
  env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
    "${TIMEOUT_CMD[@]}" "$CEREBRO_OPENCODE_CMD" "${run_args[@]}" < /dev/null 2> "$err_path" \
    | python3 "$CEREBRO_LIB_DIR/python/parse_stream.py" "$json_path" "$store_file" "$ckey"
  rc=${PIPESTATUS[0]}

  # Stale fallback: a resume can be rejected up front because opencode GC'd or no
  # longer recognizes the stored rollout -- the run then fails before emitting
  # any 'thread.started' event. Retry once fresh ONLY in that early-rejection
  # case.
  if [[ -n "$prior" ]] && (( rc != 0 )) \
     && ! grep -q '"type":"thread.started"' "$json_path"; then
    log_event "improve_resume_failed" "rc=$rc resume=$prior; retrying fresh"
    warn "improve: resume of $prior failed (rc=$rc); retrying without resume"
    : > "$json_path"
    child_store_begin "$ckey" opencode improve "$repo" improve "$out_path"
    env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
      "${TIMEOUT_CMD[@]}" "$CEREBRO_OPENCODE_CMD" "${opencode_opts[@]}" "$improve_prompt" < /dev/null 2> "$err_path" \
      | python3 "$CEREBRO_LIB_DIR/python/parse_stream.py" "$json_path" "$store_file" "$ckey"
    rc=${PIPESTATUS[0]}
  fi

  # On any failure -- non-zero exit OR empty output -- preserve the err log but
  # do NOT echo a findings path. The orchestrator must not treat a failed run's
  # stderr as findings.
  if (( rc != 0 )) || [[ ! -s "$out_path" ]]; then
    rm -f "$json_path"
    log_event "improve_failed" "rc=$rc err=$err_path out=$out_path"
    warn "opencode exited rc=$rc"
    [[ -s "$err_path" ]] && warn "see error log: $err_path"
    [[ -s "$out_path" ]] && warn "partial output preserved at: $out_path"
    die "improve: opencode run failed; not echoing a findings path"
  fi

  child_store_done "$ckey"
  rm -f "$json_path"
  [[ -s "$err_path" ]] || rm -f "$err_path"

  log_event "improve_written" "$out_path"
  echo "$out_path"
}
