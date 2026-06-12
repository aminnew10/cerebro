# cerebro lib: commands/audit
# subcommand: audit (fresh-eyes viability check of an orchestrator-written plan)
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro audit <repo> <plan-path> [--context "..."] -------
# The orchestrator writes plans itself (`cerebro plan`), so the external
# check comes from a genuinely independent model: a read-only `codex exec`
# with cwd=<repo> receives the plan, the current session spec, and any
# crucial context the orchestrator passes, verifies the plan against the
# ACTUAL code, and writes its findings (ending with a PLAN AUDIT verdict
# line) to sessions/<id>/audits/<name>.md.

cmd_audit() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local plan_path="${1:-}"; shift || true
  local context="" out_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) shift; context="${1:-}"; shift || true ;;
      --out) shift; out_name="${1:-}"; shift || true ;;
      *) die "audit: unknown arg: $1" ;;
    esac
  done
  [[ -n "$repo" && -n "$plan_path" ]] \
    || die "usage: cerebro audit <repo-abs-path> <plan-path> [--context \"<crucial context>\"] [--out <name>]"
  [[ "$repo" = /* ]] || die "audit: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "audit: repo not a directory: $repo"
  [[ -s "$plan_path" ]] || die "audit: plan file missing or empty: $plan_path"

  local audits_dir="$CEREBRO_SESSION_DIR/audits"
  mkdir -p "$audits_dir"

  # Default findings name follows the plan, so a re-audit after a revision
  # overwrites the stale findings instead of piling up files.
  local plan_name; plan_name="$(basename "${plan_path%.md}")"
  [[ -z "$out_name" ]] && out_name="$plan_name-audit"
  out_name="${out_name%.md}"
  local out_path="$audits_dir/$out_name.md"
  local err_path="${out_path%.md}.err"

  # Child-session continuity: resume the same codex conversation when the
  # same plan is re-audited after a revision, so the auditor keeps its
  # earlier exploration. Keyed by repo+role+out_name. A stale (over-TTL)
  # stored id is ignored and falls back to a fresh run.
  local store_file; store_file="$(child_sessions_file)"
  local ckey prior=""
  ckey="$(child_key "$repo" audit "$out_name")"
  if prior="$(child_session_get "$ckey")" && [[ -n "$prior" ]] && child_session_fresh "$ckey"; then
    :
  else
    prior=""
  fi

  say "cerebro: auditing $plan_path against $repo -> $out_path"
  log_event "audit_started" "plan=$plan_path out=$out_path resume=${prior:-none}"

  local audit_prompt
  audit_prompt="$(cerebro_audit_prompt)

<plan>
$(cat "$plan_path")
</plan>"

  local spec_path="$CEREBRO_SESSION_DIR/spec.md"
  if [[ -s "$spec_path" ]]; then
    audit_prompt+="

The session specification records what the user actually asked for; judge the plan's scope against it.

<spec>
$(cat "$spec_path")
</spec>"
  fi

  if [[ -n "$context" ]]; then
    audit_prompt+="

Crucial context from the orchestrator (source paths, decisions already made, constraints):

<context>
$context
</context>"
  fi

  # Run with --json so codex streams JSONL events on stdout (the only place
  # it exposes the resumable thread_id), and -o writes the human-readable
  # findings to out_path. codex_capture.py persists the thread_id the
  # instant codex emits it, so an interrupt mid-run leaves a resumable
  # record.
  local codex_opts=(exec --json --sandbox read-only --skip-git-repo-check \
                    --cd "$repo" -o "$out_path")
  [[ -n "$CEREBRO_REVIEW_MODEL" ]] && codex_opts+=(--model "$CEREBRO_REVIEW_MODEL")
  local json_path; json_path="$(mktemp)"

  local rc run_args
  if [[ -n "$prior" ]]; then
    run_args=("${codex_opts[@]}" resume "$prior" "$audit_prompt")
  else
    run_args=("${codex_opts[@]}" "$audit_prompt")
  fi
  child_store_begin "$ckey" codex audit "$repo" "$out_name" "$out_path"
  env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
    "${TIMEOUT_CMD[@]}" "$CEREBRO_CODEX_CMD" "${run_args[@]}" 2> "$err_path" \
    | python3 "$CEREBRO_LIB_DIR/python/codex_capture.py" "$json_path" "$store_file" "$ckey"
  rc=${PIPESTATUS[0]}

  # Stale fallback: a resume can be rejected up front because codex GC'd or
  # no longer recognizes the stored rollout -- the run then fails before
  # emitting any 'thread.started' event. Retry once fresh ONLY in that
  # early-rejection case.
  if [[ -n "$prior" ]] && (( rc != 0 )) \
     && ! grep -q '"type":"thread.started"' "$json_path"; then
    log_event "audit_resume_failed" "rc=$rc resume=$prior; retrying fresh"
    warn "audit: resume of $prior failed (rc=$rc); retrying without resume"
    : > "$json_path"
    env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
      "${TIMEOUT_CMD[@]}" "$CEREBRO_CODEX_CMD" "${codex_opts[@]}" "$audit_prompt" 2> "$err_path" \
      | python3 "$CEREBRO_LIB_DIR/python/codex_capture.py" "$json_path" "$store_file" "$ckey"
    rc=${PIPESTATUS[0]}
  fi

  # On any failure -- non-zero exit OR empty output -- preserve the err log
  # but do NOT echo a findings path. The orchestrator must not treat a
  # failed audit's stderr as findings.
  if (( rc != 0 )) || [[ ! -s "$out_path" ]]; then
    rm -f "$json_path"
    log_event "audit_failed" "rc=$rc err=$err_path out=$out_path"
    warn "codex exited rc=$rc"
    [[ -s "$err_path" ]] && warn "see error log: $err_path"
    [[ -s "$out_path" ]] && warn "partial output preserved at: $out_path"
    die "audit: codex run failed; not echoing a findings path"
  fi

  child_store_done "$ckey"
  rm -f "$json_path"
  [[ -s "$err_path" ]] || rm -f "$err_path"

  log_event "audit_written" "$out_path"
  echo "$out_path"
}
