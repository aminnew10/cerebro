# cerebro lib: commands/answer
# subcommand: answer (resume a paused child with an answer to its question)
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro answer <repo> "<answer>" [--role ...] -----------
# A child (plan / execute / apply-review / doc-write) runs non-interactively,
# so when it hits a genuine blocker it ends with its QUESTION as its closing
# message instead of finishing the work. `cerebro answer` resumes that exact
# child session and delivers the orchestrator's answer as the child's next
# turn, so it continues where it paused instead of redoing work.
#
# The target child is identified by role+repo. When several children of the
# same role are live in one repo (e.g. stacked execute branches), pass the
# discriminator the launch used: --branch (execute/apply-review/doc-write),
# --plan / --for-prompt (execute launched from a plan file / inline prompt with
# no --branch), or --out (plan). With no discriminator and exactly one
# resumable session of that role in the repo, that one is used.
cmd_answer() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local answer="" role="execute"
  local branch="" plan_path="" for_prompt="" out_name=""
  # Second positional, if present and not a flag, is the answer text.
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    answer="$1"; shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)       shift; role="${1:-}";       shift || true ;;
      --message)    shift; answer="${1:-}";     shift || true ;;
      --branch)     shift; branch="${1:-}";     shift || true ;;
      --plan)       shift; plan_path="${1:-}";  shift || true ;;
      --for-prompt) shift; for_prompt="${1:-}"; shift || true ;;
      --out)        shift; out_name="${1:-}";   shift || true ;;
      *) die "answer: unknown arg: $1" ;;
    esac
  done

  [[ -n "$repo" ]] \
    || die "usage: cerebro answer <repo-abs-path> \"<answer>\" [--role execute|apply-review|doc-write|plan] [--branch <name> | --plan <path> | --for-prompt <text> | --out <name>]"
  [[ "$repo" = /* ]] || die "answer: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "answer: repo not a directory: $repo"
  [[ -n "$answer" ]] || die "answer: empty answer (pass the answer text as the second argument or via --message)"
  case "$role" in
    execute|apply-review|doc-write|plan) ;;
    *) die "answer: unknown role: $role (expected execute|apply-review|doc-write|plan)" ;;
  esac

  # Build the launch discriminator the original command keyed on, when the
  # orchestrator passed one. Left empty -> auto-match by role+repo below.
  local disc=""
  case "$role" in
    execute)
      if   [[ -n "$branch" ]];     then disc="$branch"
      elif [[ -n "$plan_path" ]];  then disc="plan:$plan_path"
      elif [[ -n "$for_prompt" ]]; then disc="prompt:$for_prompt"
      fi ;;
    apply-review|doc-write) [[ -n "$branch" ]]   && disc="$branch" ;;
    plan)                   [[ -n "$out_name" ]] && disc="$out_name" ;;
  esac

  # Resolve the kept session: explicit discriminator -> exact key; otherwise
  # auto-match the single resumable session of this role in the repo.
  local ckey="" prior="" label=""
  if [[ -n "$disc" ]]; then
    ckey="$(child_key "$repo" "$role" "$disc")"
    prior="$(child_session_get "$ckey")"
    if [[ -z "$prior" ]] || ! child_session_fresh "$ckey"; then
      die "answer: no fresh $role session for that target in $repo. Run 'cerebro status', or omit the discriminator to auto-match."
    fi
    label="$disc"
  else
    local rows n
    rows="$(child_session_match "$role" "$repo")"
    n="$(printf '%s' "$rows" | grep -c .)"
    if (( n == 0 )); then
      die "answer: no resumable $role session found in $repo (the child may never have run, or its session expired)."
    elif (( n > 1 )); then
      { printf 'cerebro: answer: several %s sessions in %s -- pass --branch/--out to pick one:\n' "$role" "$repo"
        while IFS=$'\t' read -r _k _id _br _st _up; do
          [[ -z "$_k" ]] && continue
          printf '  %s (status=%s, updated=%s)\n' "$_br" "$_st" "$_up"
        done <<<"$rows"
      } >&2
      exit 1
    fi
    IFS=$'\t' read -r ckey prior label _ _ <<<"$rows"
  fi

  local sys_prompt; sys_prompt="$(child_sys_prompt "$role")"
  local child_log; child_log="$(child_log_path "answer-$role")"
  local store_file; store_file="$(child_sessions_file)"

  local opts=(-p --permission-mode bypassPermissions
              --allowedTools "$(child_allowed_tools "$role")"
              --output-format stream-json --verbose
              --resume "$prior"
              --append-system-prompt "$sys_prompt")
  [[ -n "$CEREBRO_MODEL" ]] && opts+=(--model "$CEREBRO_MODEL")

  local child_prompt
  child_prompt="$(printf 'The cerebro orchestrator is answering the question you raised when you paused. Use this answer and CONTINUE the task from where you stopped -- do not restart work you have already completed. If you hit another genuine blocker, pause again the same way (end with a single clear question).\n\n<answer>\n%s\n</answer>\n' "$answer")"

  say "cerebro: answering $role child in $repo${label:+ ($label)}"
  log_event "answer_started" "role=$role repo=$repo target=${label:-auto} resume=$prior"

  # plan writes its (now-completed) output back to the plan file; the mutating
  # roles push commits, so we capture only the child's closing message to
  # surface (it may complete, or pause again with a further question).
  local rc result_path="" msg_capture=""
  if [[ "$role" == plan ]]; then
    result_path="$CEREBRO_SESSION_DIR/plans/$label.md"
  else
    msg_capture="$(mktemp)"; result_path="$msg_capture"
  fi

  child_store_begin "$ckey" claude "$role" "$repo" "$label" "$child_log"
  ( cd "$repo" && printf '%s' "$child_prompt" \
      | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
        "${TIMEOUT_CMD[@]}" claude "${opts[@]}" 2>/dev/null \
      | tee "$child_log" \
      | python3 -c "$PY_PARSE_STREAM" "$result_path" "" "$store_file" "$ckey" )
  rc=$?

  if (( rc != 0 )); then
    [[ -n "$msg_capture" ]] && rm -f "$msg_capture"
    log_event "answer_failed" "rc=$rc role=$role resume=$prior log=$child_log"
    die "answer: resuming the $role child failed (rc=$rc); see $child_log"
  fi

  child_store_done "$ckey"
  log_event "answer_finished" "role=$role log=$child_log"
  if [[ "$role" == plan ]]; then
    echo "$result_path"
  else
    surface_child_reply "$msg_capture" "$role"
    rm -f "$msg_capture"
    echo "$child_log"
  fi
}
