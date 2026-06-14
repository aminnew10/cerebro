# cerebro lib: commands/execute
# subcommand: execute
# Sourced by bin/cerebro; not meant to be executed directly.

# execute_restart_revert <repo> <base> <branch> [start_sha] -- undo a strayed
# paired child's work so the orchestrator can relaunch FRESH "as if the agent
# never started". Best-effort: every step is guarded so a missing remote/PR
# never blocks the restart, and it NEVER deletes the base/default branch. Drops
# the working tree, returns to the base ref, and tears down the strayed branch
# and its PR (locally + on origin). Logs a one-line summary of what was undone.
#
# Two strayed-work shapes:
#   * SEPARATE branch (base ref != strayed branch): the child branched off and
#     committed there, leaving the base ref untouched -- delete the strayed
#     branch and its PR; the base ref already holds no new commits.
#   * SAME branch (existing-branch mode, base ref == branch): the child
#     committed onto the base ref itself, so deleting a separate branch undoes
#     nothing. When <start_sha> (the base ref's HEAD captured BEFORE the child
#     launched) is given, rewind the base ref to EXACTLY that commit -- and only
#     that commit, never further back -- to drop this run's commits.
#
# LOCAL cleanup gates the "clean slate" claim: after attempting the revert this
# VERIFIES the repo is on the base ref, the working tree is clean, the strayed
# branch is gone, and (same-branch case) HEAD is back at <start_sha>. On success
# it returns 0 and prints nothing; if LOCAL cleanup fell short it prints a
# one-line description of what is still wrong (for the caller to surface) and
# returns 1. REMOTE teardown stays best-effort and never gates the verdict.
execute_restart_revert() {
  local repo="$1" base="$2" branch="$3" start_sha="${4:-}"
  git -C "$repo" reset --hard >/dev/null 2>&1 || true
  git -C "$repo" clean -fd >/dev/null 2>&1 || true

  # Resolve the base ref: explicit --base, else origin/HEAD's branch, else main.
  local baseref="$base"
  if [[ -z "$baseref" ]]; then
    baseref="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
               | sed 's#^origin/##')"
  fi
  [[ -n "$baseref" ]] || baseref="main"

  # Resolve the strayed branch: explicit --branch, else the current HEAD branch
  # when it differs from the base ref (the reaped child was on its own branch).
  local strayed="$branch" current
  current="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "$strayed" && -n "$current" && "$current" != "$baseref" && "$current" != "HEAD" ]]; then
    strayed="$current"
  fi

  git -C "$repo" checkout "$baseref" >/dev/null 2>&1 || true

  # same_branch is the existing-branch case: no separate strayed branch to
  # delete because the child committed onto the base ref itself.
  local summary="reset+clean; on $baseref" same_branch=1
  if [[ -n "$strayed" && "$strayed" != "$baseref" ]]; then
    same_branch=0
    git -C "$repo" branch -D "$strayed" >/dev/null 2>&1 || true
    summary+="; deleted local $strayed"
    if [[ -n "$(git -C "$repo" ls-remote --heads origin "$strayed" 2>/dev/null)" ]]; then
      if ( cd "$repo" && gh pr close "$strayed" --delete-branch >/dev/null 2>&1 ); then
        summary+="; closed PR + deleted origin $strayed"
      else
        git -C "$repo" push origin --delete "$strayed" >/dev/null 2>&1 || true
        summary+="; deleted origin $strayed"
      fi
    fi
  fi

  # Same-branch case: the child's commits live on the base ref, so reset+clean
  # above only dropped uncommitted work -- the commits remain. Rewind the base
  # ref to the commit it was on before this run. ONLY ever to that captured
  # commit (never further back, never to anything but the base ref's own start
  # point), so this can never rewrite shared history beyond THIS run's commits.
  if (( same_branch )) && [[ -n "$start_sha" ]]; then
    git -C "$repo" reset --hard "$start_sha" >/dev/null 2>&1 || true
    summary+="; reset $baseref to ${start_sha:0:12}"
  fi

  # Verify the LOCAL clean slate. The revert above was best-effort, so confirm
  # it actually landed: on the base ref, clean tree, strayed branch gone. Only
  # LOCAL state gates this -- remote teardown is intentionally not checked.
  local problems="" now_branch
  now_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$now_branch" != "$baseref" ]]; then
    problems+="; not on base ref (HEAD=${now_branch:-unknown}, expected $baseref)"
  fi
  if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    problems+="; working tree not clean"
  fi
  if [[ -n "$strayed" && "$strayed" != "$baseref" ]] \
     && git -C "$repo" show-ref --verify --quiet "refs/heads/$strayed"; then
    problems+="; strayed branch $strayed still present"
  fi
  if (( same_branch )) && [[ -n "$start_sha" ]]; then
    local now_sha; now_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$now_sha" != "$start_sha" ]]; then
      problems+="; HEAD not back at pre-run commit (HEAD=${now_sha:0:12}, expected ${start_sha:0:12})"
    fi
  fi

  if [[ -n "$problems" ]]; then
    log_event "execute_restart_revert_incomplete" "$summary$problems"
    printf 'LOCAL cleanup incomplete: %s' "${problems#; }"
    return 1
  fi
  log_event "execute_restart_reverted" "$summary"
  return 0
}

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

  if [[ -z "$base_branch" && -n "$new_branch" ]]; then
    local current_branch
    current_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "$current_branch" == "$new_branch" ]]; then
      base_branch="$new_branch"
    fi
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
  # If both are the same branch -- either explicitly, or because --base was
  # omitted while --branch names the current branch -- the user is asking to
  # continue an existing PR branch, not to create a branch-against-itself PR.
  # When neither is given the child keeps its default behaviour (fetch the
  # repo's base branch, branch from it, open the PR against the default base).
  local existing_branch_mode=0
  if [[ -n "$base_branch" && -n "$new_branch" && "$base_branch" == "$new_branch" ]]; then
    existing_branch_mode=1
  fi
  local branch_instr=""
  if (( existing_branch_mode )); then
    branch_instr='EXISTING-BRANCH MODE -- this overrides the default fetch/branch/PR creation behaviour:'
    branch_instr+=$'\n'"  * Fetch '$new_branch' from origin (git fetch origin $new_branch)."
    branch_instr+=$'\n'"  * Check out the existing branch named EXACTLY '$new_branch' and update it from origin/$new_branch before making changes."
    branch_instr+=$'\n'"  * Do NOT create a new branch and do NOT invent a different branch name."
    branch_instr+=$'\n'"  * Commit the work on '$new_branch' and push commits to origin '$new_branch'."
    branch_instr+=$'\n'"  * Do NOT open a new pull request. Update the existing PR for '$new_branch' by pushing to that branch. If no such PR exists, stop and report that instead of creating one."
  elif [[ -n "$base_branch" || -n "$new_branch" ]]; then
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

  # Child-session continuity is only for incomplete work. A completed execute
  # must not bleed provider context into the next sub-agent, even when a trunk
  # based suite runs multiple plans on the same branch. The key always includes
  # the plan/prompt; --branch narrows it but never replaces it.
  local store_file; store_file="$(child_sessions_file)"
  local key_disc; key_disc="$(execute_child_disc "$new_branch" "$plan_path" "$prompt_text")"
  local ckey prior=""
  ckey="$(child_key "$repo" execute "$key_disc")"
  if prior="$(child_session_get "$ckey")" && [[ -n "$prior" ]] && child_session_running_fresh "$ckey"; then
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
    if (( existing_branch_mode )); then
      printf "Execute the following plan in this repository. Fetch and check out the existing branch named '%s', implement, commit, and push to that branch so its existing PR updates. Do NOT create a new branch or open a new PR.\n\n" "$new_branch"
    else
      printf 'Execute the following plan in this repository. Fetch the base branch first, branch from the freshly-fetched base, implement, commit, push, and open a PR via gh.\n\n'
    fi
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
  local PAIR_SID="" PAIR_OPTS=() PAIR_FIFO="" PAIR_STEER="" PAIR_IDLE="" \
        PAIR_PGID="" PAIR_STALL="" PAIR_STALL_BUSY="" PAIR_LAUNCH=()
  (( pair )) && pair_begin execute "$repo" "$new_branch" "$child_log" "$prior"

  # Capture the working branch's HEAD BEFORE the child launches. In
  # existing-branch mode the child commits onto this same branch, so a restart
  # must rewind it to here to drop this run's commits (execute_restart_revert).
  local start_sha; start_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"

  local stall_n=0
  while :; do
    local run_opts=("${opts[@]}")
    [[ -n "$prior" ]] && run_opts+=(--resume "$prior")
    (( pair )) && run_opts+=("${PAIR_OPTS[@]}")

    # Mark the child in-flight (preserving any prior id we are resuming) BEFORE
    # it launches, so an interrupt now leaves a resumable record.
    child_store_begin "$ckey" claude execute "$repo" "${new_branch:-auto}" "$child_log" "${prior:+preserve-id}"
    ( cd "$repo" && printf '%s' "$child_prompt" \
        | pair_feed "$pair" "$PAIR_FIFO" "$PAIR_STEER" "$child_log" "$PAIR_IDLE" "$PAIR_PGID" "$PAIR_STALL" "$PAIR_STALL_BUSY" \
        | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
          ${PAIR_LAUNCH[@]+"${PAIR_LAUNCH[@]}"} "${TIMEOUT_CMD[@]}" claude "${run_opts[@]}" 2>/dev/null \
        | tee "$child_log" \
        | python3 "$CEREBRO_LIB_DIR/python/parse_stream.py" "$msg_capture" "$id_capture" "$store_file" "$ckey" )
    rc=$?
    pair_cleanup "$pair"

    # Stale fallback: retry fresh only when the resumed run never started and
    # this was not a stall. A stall is handled by the outer resume loop.
    if (( rc != 0 )) && ! pair_stalled "$child_log" && [[ -n "$prior" ]] && [[ ! -s "$id_capture" ]]; then
      log_event "execute_resume_failed" "rc=$rc resume=$prior; retrying fresh"
      warn "execute: resume of $prior failed (rc=$rc); retrying without resume"
      : > "$id_capture"
      local retry_opts=("${opts[@]}")
      if (( pair )); then
        pair_begin execute "$repo" "$new_branch" "$child_log" ""
        retry_opts+=("${PAIR_OPTS[@]}")
      fi
      child_store_begin "$ckey" claude execute "$repo" "${new_branch:-auto}" "$child_log"
      ( cd "$repo" && printf '%s' "$child_prompt" \
          | pair_feed "$pair" "$PAIR_FIFO" "$PAIR_STEER" "$child_log" "$PAIR_IDLE" "$PAIR_PGID" "$PAIR_STALL" "$PAIR_STALL_BUSY" \
          | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
            ${PAIR_LAUNCH[@]+"${PAIR_LAUNCH[@]}"} "${TIMEOUT_CMD[@]}" claude "${retry_opts[@]}" 2>/dev/null \
          | tee "$child_log" \
          | python3 "$CEREBRO_LIB_DIR/python/parse_stream.py" "$msg_capture" "$id_capture" "$store_file" "$ckey" )
      rc=$?
      pair_cleanup "$pair"
    fi

    if (( pair )) && pair_stalled "$child_log"; then
      if (( stall_n < ${CEREBRO_PAIR_STALL_RETRIES:-2} )); then
        stall_n=$((stall_n + 1))
        pair_stall_backoff "$stall_n"
        pair_stall_clear "$child_log"
        pair_begin execute "$repo" "$new_branch" "$child_log" "$PAIR_SID"
        prior="$PAIR_SID"
        continue
      fi
      pair_stall_clear "$child_log"
      log_event "pair_stall_giveup" "after=$stall_n stalls log=$child_log resume=$PAIR_SID"
      rm -f "$id_capture" "$msg_capture"
      die "execute: paired child stalled $stall_n time(s) and was not restarted further; it remains resumable (id $PAIR_SID) -- see $child_log"
    fi
    break
  done

  # Restart: the developer/observer ran `cerebro restart`, the pump reaped the
  # child and dropped a `.restart` marker holding a diagnosis. Treat this as a
  # clean abandonment (NOT a crash): revert the strayed work to a clean slate,
  # mark the child done so the next execute never resumes the poisoned session,
  # surface the diagnosis, and return 0 so the orchestrator can relaunch fresh.
  if (( pair )) && pair_restarted "$child_log"; then
    local diag; diag="$(pair_restart_read "$child_log")"
    local revert_problems revert_rc
    revert_problems="$(execute_restart_revert "$repo" "$base_branch" "$new_branch" "$start_sha")"
    revert_rc=$?
    child_store_done "$ckey"
    pair_cleanup "$pair"
    pair_restart_clear "$child_log"
    log_event "execute_restarted" "log=$child_log base=${base_branch:-default} branch=${new_branch:-auto} clean=$(( revert_rc == 0 ))"
    rm -f "$id_capture" "$msg_capture"
    printf '=== RESTART REQUESTED ===\n'
    printf '%s\n' "$diag"
    if (( revert_rc == 0 )); then
      printf '(repo=%s base=%s branch=%s -- the strayed work has been reverted to a clean slate)\n' \
        "$repo" "${base_branch:-default}" "${new_branch:-auto}"
    else
      printf '(repo=%s base=%s branch=%s -- WARNING: the repo is NOT a clean slate: %s -- reconcile the repo manually before relaunching)\n' \
        "$repo" "${base_branch:-default}" "${new_branch:-auto}" "$revert_problems"
    fi
    printf '=== END RESTART REQUESTED ===\n'
    say "cerebro: paired child was RESTARTED -- fold the diagnosis above into a corrected plan/prompt (make the prior mistake explicit at the START), then re-run 'cerebro execute' FRESH on the same branch."
    return 0
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
  local child_id; child_id="$(cat "$id_capture" 2>/dev/null || true)"
  rm -f "$id_capture"
  log_event "execute_finished" "$child_log"
  pair_report "$pair" "$child_log"
  surface_child_reply "$msg_capture" execute "$child_id"
  rm -f "$msg_capture"
  echo "$child_log"
}
