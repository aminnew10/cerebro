# cerebro lib: commands/execute
# subcommand: execute
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro execute <repo> <plan-path> ----------------------

cmd_execute() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local plan_path=""
  local prompt_text=""
  local base_branch=""
  local new_branch=""
  local pair=0
  # Second positional, if present and not a flag, is the plan path.
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    plan_path="$1"; shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt) shift; prompt_text="${1:-}"; shift || true ;;
      --base)   shift; base_branch="${1:-}"; shift || true ;;
      --branch) shift; new_branch="${1:-}";  shift || true ;;
      --pair)   pair=1; shift ;;
      *) die "execute: unknown arg: $1" ;;
    esac
  done
  [[ -n "$repo" ]] \
    || die "usage: cerebro execute <repo-abs-path> (<plan-path> | --prompt \"<text>\") [--base <branch>] [--branch <name>]"
  [[ "$repo" = /* ]] || die "execute: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "execute: repo not a directory: $repo"
  if [[ -n "$plan_path" && -n "$prompt_text" ]]; then
    die "execute: pass either <plan-path> or --prompt, not both"
  fi
  if [[ -z "$plan_path" && -z "$prompt_text" ]]; then
    die "execute: requires <plan-path> or --prompt \"<text>\""
  fi
  if [[ -n "$plan_path" ]]; then
    [[ -r "$plan_path" ]] || die "execute: cannot read plan: $plan_path"
  fi

  local plan_body source_desc
  if [[ -n "$plan_path" ]]; then
    plan_body="$(cat "$plan_path")"
    source_desc="plan=$plan_path"
  else
    plan_body="$prompt_text"
    source_desc="prompt=inline"
  fi

  local child_log; child_log="$(child_log_path execute)"

  local sys_prompt; sys_prompt="$(child_sys_prompt execute)"

  # Stacked-branch support. --base pins the branch this PR forks from and
  # targets (so a suite of plans can stack: plan 1 off main, plan 2 off
  # plan 1's branch, ...); --branch pins the new branch's name so the
  # orchestrator deterministically knows it for the next plan's --base.
  # When neither is given the child keeps its default behaviour (fetch the
  # repo's base branch, branch from it, open the PR against the default base).
  local branch_instr=""
  if [[ -n "$base_branch" || -n "$new_branch" ]]; then
    branch_instr='STACKED-BRANCH MODE -- this overrides the default fetch/branch/PR-base behaviour:'
    if [[ -n "$base_branch" ]]; then
      branch_instr+=$'\n'"  * Fetch '$base_branch' from origin (git fetch origin $base_branch) and create your new branch from origin/$base_branch -- NOT from origin/main or any other default base."
    fi
    if [[ -n "$new_branch" ]]; then
      branch_instr+=$'\n'"  * Name the new branch EXACTLY '$new_branch' (it already follows the repo's conventions; do not invent a different name)."
    fi
    if [[ -n "$base_branch" ]]; then
      branch_instr+=$'\n'"  * Open the pull request with its base set to '$base_branch' (gh pr create --base $base_branch) so this PR stacks on top of it."
    fi
  fi

  if [[ -n "$plan_path" ]]; then
    say "cerebro: executing $plan_path in $repo${base_branch:+ (base=$base_branch)}${new_branch:+ (branch=$new_branch)}"
  else
    say "cerebro: executing inline prompt in $repo${base_branch:+ (base=$base_branch)}${new_branch:+ (branch=$new_branch)}"
  fi

  # Child-session continuity: resume the same provider conversation for
  # repeated executes on the same line of work -- and, crucially, for an
  # execute that was INTERRUPTED mid-run (its id is persisted at startup, so
  # the next call resumes the half-done work instead of redoing it). The key
  # discriminator is --branch when given; without it we key on the plan path
  # or the inline prompt so re-issuing the same command resumes the same
  # conversation. A stale (over-TTL) stored id is ignored and falls back to a
  # fresh run.
  local store_file; store_file="$(child_sessions_file)"
  local key_disc="${new_branch:-}"
  if [[ -z "$key_disc" ]]; then
    [[ -n "$plan_path" ]] && key_disc="plan:$plan_path" || key_disc="prompt:$prompt_text"
  fi
  local ckey prior=""
  ckey="$(child_key "$repo" execute "$key_disc")"
  if prior="$(child_session_get "$ckey")" && [[ -n "$prior" ]] && child_session_fresh "$ckey"; then
    :
  else
    prior=""
  fi
  log_event "execute_started" "$source_desc repo=$repo base=${base_branch:-default} branch=${new_branch:-auto} resume=${prior:-none}"

  local opts=(-p --permission-mode bypassPermissions
              --allowedTools "$(child_allowed_tools execute)"
              --output-format stream-json --verbose
              --append-system-prompt "$sys_prompt")
  [[ -n "$CEREBRO_MODEL" ]] && opts+=(--model "$CEREBRO_MODEL")

  # Bootstrap files: cerebro ships defaults at
  # $CEREBRO_HOME/templates/{AGENTS.md,CLAUDE.md}. We hand them to the
  # child claude along with an instruction to create them in the repo
  # only when missing; existing files are left alone. The user can edit
  # the template files to customize what new repos get.
  local agents_template="" claude_template=""
  if [[ -r "$CEREBRO_HOME/templates/AGENTS.md" ]]; then
    agents_template="$(cat "$CEREBRO_HOME/templates/AGENTS.md")"
  fi
  if [[ -r "$CEREBRO_HOME/templates/CLAUDE.md" ]]; then
    claude_template="$(cat "$CEREBRO_HOME/templates/CLAUDE.md")"
  fi

  local child_prompt
  child_prompt="$(
    printf 'Execute the following plan in this repository. Fetch the base branch first, branch from the freshly-fetched base, implement, commit, push, and open a PR via gh.\n\n'
    printf 'Before implementing the plan, ensure the repo has AGENTS.md and CLAUDE.md at the root:\n'
    printf '  * If AGENTS.md is missing, create it from <bootstrap-agents-md> below as a SEPARATE first commit (e.g. "chore: add AGENTS.md") before doing the plan work.\n'
    printf '  * If CLAUDE.md is missing, create it from <bootstrap-claude-md> in the same first commit.\n'
    printf '  * If either file already exists, do NOT modify it.\n'
    printf 'Then read AGENTS.md (existing or just-written) and follow its branch/commit rules for the rest of this run.\n\n'
    printf '<bootstrap-agents-md>\n%s\n</bootstrap-agents-md>\n\n' "$agents_template"
    printf '<bootstrap-claude-md>\n%s\n</bootstrap-claude-md>\n\n' "$claude_template"
    [[ -n "$branch_instr" ]] && printf '%s\n\n' "$branch_instr"
    printf '<plan>\n%s\n</plan>\n' "$plan_body"
  )"

  local rc id_capture msg_capture
  id_capture="$(mktemp)"
  msg_capture="$(mktemp)"
  local PAIR_SID="" PAIR_OPTS=() PAIR_FIFO="" PAIR_STEER="" PAIR_IDLE=""
  (( pair )) && pair_begin execute "$repo" "$new_branch" "$child_log" "$prior"
  local run_opts=("${opts[@]}")
  [[ -n "$prior" ]] && run_opts+=(--resume "$prior")
  (( pair )) && run_opts+=("${PAIR_OPTS[@]}")

  # Mark the child in-flight (preserving any prior id we are resuming) BEFORE
  # it launches, so an interrupt now leaves a resumable record.
  child_store_begin "$ckey" claude execute "$repo" "${new_branch:-auto}" "$child_log"
  ( cd "$repo" && printf '%s' "$child_prompt" \
      | pair_feed "$pair" "$PAIR_FIFO" "$PAIR_STEER" "$child_log" "$PAIR_IDLE" \
      | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
        "${TIMEOUT_CMD[@]}" claude "${run_opts[@]}" 2>/dev/null \
      | tee "$child_log" \
      | python3 "$CEREBRO_LIB_DIR/python/parse_stream.py" "$msg_capture" "$id_capture" "$store_file" "$ckey" )
  rc=$?
  pair_cleanup "$pair"

  # Stale fallback: a resume can be rejected up front because the provider
  # GC'd or no longer recognizes the stored conversation. Retry once fresh
  # (no --resume) ONLY when the resumed run did no work before failing -- i.e.
  # it never emitted a session/init event, so id_capture stays empty and
  # nothing was committed or edited. If the resumed child DID start a session
  # (id_capture is non-empty) and then failed, we must NOT re-run fresh: this
  # is a mutating phase, so a fresh re-run would duplicate or partially redo
  # work already done. Such a failure is fatal and is handled below like any
  # other child failure.
  if (( rc != 0 )) && [[ -n "$prior" ]] && [[ ! -s "$id_capture" ]]; then
    log_event "execute_resume_failed" "rc=$rc resume=$prior; retrying fresh"
    warn "execute: resume of $prior failed (rc=$rc); retrying without resume"
    : > "$id_capture"
    local retry_opts=("${opts[@]}")
    # The rejected resume's session id is dead; pair the retry on a fresh one.
    if (( pair )); then
      pair_begin execute "$repo" "$new_branch" "$child_log" ""
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
    log_event "execute_failed" "rc=$rc log=$child_log"
    die "execute: child claude failed (rc=$rc); see $child_log"
  fi

  # The child's provider id was already persisted at startup (see
  # parse_stream.py); just mark this line of work cleanly finished so it no
  # longer shows up as interrupted in `cerebro status`.
  child_store_done "$ckey"
  rm -f "$id_capture"
  log_event "execute_finished" "$child_log"
  pair_report "$pair" "$child_log"
  surface_child_reply "$msg_capture" execute
  rm -f "$msg_capture"
  echo "$child_log"
}

