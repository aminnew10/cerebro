# cerebro lib: commands/doc-write
# subcommand: doc-write
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro doc-write <repo> <plan> [--notes ...] -----------

cmd_doc_write() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local plan=""
  local prompt_text=""
  local notes=""
  local pair=0
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    plan="$1"; shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt) shift; prompt_text="${1:-}"; shift || true ;;
      --notes)  shift; notes="${1:-}";       shift || true ;;
      --pair)   pair=1; shift ;;
      *) die "doc-write: unknown arg: $1" ;;
    esac
  done
  [[ -n "$repo" ]] \
    || die "usage: cerebro doc-write <repo-abs-path> (<plan-path> [--notes \"...\"] | --prompt \"<text>\")"
  [[ "$repo" = /* ]] || die "doc-write: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "doc-write: repo not a directory: $repo"
  if [[ -n "$plan" && -n "$prompt_text" ]]; then
    die "doc-write: pass either <plan-path> or --prompt, not both"
  fi
  if [[ -z "$plan" && -z "$prompt_text" ]]; then
    die "doc-write: requires <plan-path> or --prompt \"<text>\""
  fi
  if [[ -n "$prompt_text" && -n "$notes" ]]; then
    die "doc-write: --notes is only meaningful with a plan file; bake the context into --prompt instead"
  fi
  if [[ -n "$plan" ]]; then
    [[ -r "$plan" ]] || die "doc-write: cannot read plan: $plan"
  fi

  local plan_body source_desc
  if [[ -n "$plan" ]]; then
    plan_body="$(cat "$plan")"
    source_desc="plan=$plan"
  else
    plan_body="$prompt_text"
    source_desc="prompt=inline"
  fi

  local child_log; child_log="$(child_log_path doc-write)"

  local sys_prompt; sys_prompt="$(child_sys_prompt doc-write)"

  # Child-session continuity: doc-write stays on the current branch, keyed on
  # repo+role+branch. A doc-write INTERRUPTED mid-run resumes its conversation
  # instead of redoing the doc edits.
  local store_file; store_file="$(child_sessions_file)"
  local dw_branch; dw_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  local ckey prior=""
  ckey="$(child_key "$repo" doc-write "${dw_branch:-default}")"
  if prior="$(child_session_get "$ckey")" && [[ -n "$prior" ]] && child_session_fresh "$ckey"; then
    :
  else
    prior=""
  fi

  say "cerebro: updating docs in $repo"
  log_event "doc_write_started" "$source_desc resume=${prior:-none}"

  local opts=(-p --permission-mode bypassPermissions
              --allowedTools "$(child_allowed_tools doc-write)"
              --output-format stream-json --verbose
              --append-system-prompt "$sys_prompt")
  [[ -n "$CEREBRO_MODEL" ]] && opts+=(--model "$CEREBRO_MODEL")

  local PAIR_SID="" PAIR_OPTS=() PAIR_FIFO="" PAIR_STEER="" PAIR_IDLE=""
  if (( pair )); then
    pair_begin doc-write "$repo" "$dw_branch" "$child_log" "$prior"
    opts+=("${PAIR_OPTS[@]}")
  fi

  local child_prompt
  child_prompt="$(printf 'Update the docs to reflect the work described in the plan and the recent commits on this branch. Commit and push on the current branch.\n\n<orchestrator-notes>\n%s\n</orchestrator-notes>\n\n<plan>\n%s\n</plan>\n' "$notes" "$plan_body")"

  local rc id_capture msg_capture; id_capture="$(mktemp)"; msg_capture="$(mktemp)"
  local run_opts=("${opts[@]}")
  [[ -n "$prior" ]] && run_opts+=(--resume "$prior")
  child_store_begin "$ckey" claude doc-write "$repo" "${dw_branch:-default}" "$child_log"
  ( cd "$repo" && printf '%s' "$child_prompt" \
      | pair_feed "$pair" "$PAIR_FIFO" "$PAIR_STEER" "$child_log" "$PAIR_IDLE" \
      | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
        "${TIMEOUT_CMD[@]}" claude "${run_opts[@]}" 2>/dev/null \
      | tee "$child_log" \
      | python3 "$CEREBRO_LIB_DIR/python/parse_stream.py" "$msg_capture" "$id_capture" "$store_file" "$ckey" )
  rc=$?
  pair_cleanup "$pair"

  # Stale fallback (same rule as execute): only retry fresh when the resumed
  # run never started (no init -> id_capture empty), so nothing was written.
  if (( rc != 0 )) && [[ -n "$prior" ]] && [[ ! -s "$id_capture" ]]; then
    log_event "doc_write_resume_failed" "rc=$rc resume=$prior; retrying fresh"
    warn "doc-write: resume of $prior failed (rc=$rc); retrying without resume"
    : > "$id_capture"
    local retry_opts=("${opts[@]}")
    if (( pair )); then
      pair_begin doc-write "$repo" "$dw_branch" "$child_log" ""
      retry_opts+=("${PAIR_OPTS[@]}")
    fi
    ( cd "$repo" && printf '%s' "$child_prompt" \
        | pair_feed "$pair" "$PAIR_FIFO" "$PAIR_STEER" "$child_log" "$PAIR_IDLE" \
        | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
          "${TIMEOUT_CMD[@]}" claude "${retry_opts[@]}" 2>/dev/null \
        | tee "$child_log" \
        | python3 "$CEREBRO_LIB_DIR/python/parse_stream.py" "$msg_capture" "$id_capture" "$store_file" "$ckey" )
    rc=$?
    pair_cleanup "$pair"
  fi

  if (( rc != 0 )); then
    rm -f "$id_capture" "$msg_capture"
    log_event "doc_write_failed" "rc=$rc log=$child_log"
    die "doc-write: child claude failed (rc=$rc); see $child_log"
  fi
  child_store_done "$ckey"
  rm -f "$id_capture"
  log_event "doc_write_finished" "$child_log"
  pair_report "$pair" "$child_log"
  surface_child_reply "$msg_capture" doc-write
  rm -f "$msg_capture"
  echo "$child_log"
}

