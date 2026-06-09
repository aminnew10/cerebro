# cerebro lib: commands/review
# subcommands: review / apply-review
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro review <repo> [--base <ref>] --------------------

cmd_review() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local base=""
  local explicit_base="false"
  local criteria_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) shift; base="${1:-}"; explicit_base="true"; shift || true ;;
      --criteria-file) shift; criteria_file="${1:-}"; shift || true ;;
      *) die "review: unknown arg: $1" ;;
    esac
  done
  [[ -n "$repo" ]] || die "usage: cerebro review <repo-abs-path> [--base <ref>] [--criteria-file <plan-path>]"
  [[ "$repo" = /* ]] || die "review: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "review: repo not a directory: $repo"

  # --criteria-file points at the plan whose acceptance criteria codex must
  # check the change against. Validate it up front (before any git/codex
  # work) so a typo fails fast rather than after a full review.
  local criteria_block=""
  if [[ -n "$criteria_file" ]]; then
    [[ -r "$criteria_file" && -s "$criteria_file" ]] \
      || die "review: cannot read --criteria-file (or it is empty): $criteria_file"
    criteria_block="$(cat "$criteria_file")"
  fi

  # Canonical worktree root keys the per-repo review-state file so
  # re-reviews diff against the previously-reviewed commit instead of
  # main/origin (otherwise codex would re-evaluate the entire PR diff
  # every time apply-review made new commits).
  local canonical_repo
  canonical_repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || die "review: not a git worktree: $repo"
  local repo_key
  repo_key="$(repo_state_key "$repo")" \
    || die "review: not a git worktree: $repo"
  local state_dir="$CEREBRO_SESSION_DIR/review-state"
  local state_file="$state_dir/$repo_key.json"

  # Child-session continuity: resume the same codex conversation for repeated
  # reviews on the same branch -- including a review that was INTERRUPTED
  # mid-run (its thread_id is persisted as soon as codex emits it). Keyed by
  # repo+role+branch (role=review keeps it distinct from the execute
  # conversation). A stale (over-TTL) stored id is ignored and falls back to a
  # fresh run.
  local store_file; store_file="$(child_sessions_file)"
  local ckey="" prior="" review_branch
  review_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [[ -n "$review_branch" ]]; then
    ckey="$(child_key "$canonical_repo" review "$review_branch")"
    if prior="$(child_session_get "$ckey")" && [[ -n "$prior" ]] && child_session_fresh "$ckey"; then
      :
    else
      prior=""
    fi
  fi

  local base_ref base_description
  local using_review_state="false"

  # If the orchestrator did not pin --base, prefer the previously-reviewed
  # commit so codex only inspects what changed since the last review.
  # Preconditions guard against stale state after rebases / branch
  # switches: the recorded SHA must still parse, still be an ancestor of
  # HEAD, and the branch name must match.
  if [[ "$explicit_base" == "false" && -f "$state_file" ]]; then
    local last_sha last_branch current_branch
    last_sha="$(jq -r '.last_reviewed_sha // empty' "$state_file" 2>/dev/null)"
    last_branch="$(jq -r '.branch // empty' "$state_file" 2>/dev/null)"
    current_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [[ -n "$last_sha" && -n "$last_branch" && -n "$current_branch" \
          && "$last_branch" == "$current_branch" ]] \
       && git -C "$repo" rev-parse --verify --quiet "$last_sha^{commit}" \
            >/dev/null 2>&1 \
       && git -C "$repo" merge-base --is-ancestor "$last_sha" HEAD \
            >/dev/null 2>&1; then
      local short_sha
      short_sha="$(git -C "$repo" rev-parse --short "$last_sha" 2>/dev/null)"
      base_ref="$last_sha"
      base_description="previously-reviewed commit $short_sha"
      using_review_state="true"
      say "cerebro: re-review mode, diffing against $short_sha"
    fi
  fi

  if [[ "$using_review_state" == "false" ]]; then
    # Resolve the base ref: explicit --base wins; otherwise try the PR
    # base via gh; then origin/HEAD; then 'main'.
    if [[ -z "$base" ]]; then
      base="$(cd "$repo" && gh pr view --json baseRefName -q .baseRefName 2>/dev/null)"
    fi
    if [[ -z "$base" ]]; then
      base="$(cd "$repo" && git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
    fi
    [[ -z "$base" ]] && base="main"

    # Prefer the remote-tracking ref when it exists, so reviews still work
    # on branches whose local copy of the base is stale. Fall back to the
    # local branch, then to a raw commit. Matches dev-tools `review`.
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$base"; then
      base_ref="origin/$base"
    elif git -C "$repo" show-ref --verify --quiet "refs/heads/$base"; then
      base_ref="$base"
    elif git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
      base_ref="$base"
    else
      die "review: could not resolve base reference '$base' in $repo"
    fi
    if [[ "$base_ref" == "$base" ]]; then
      base_description="base reference '$base'"
    else
      base_description="base reference '$base' (resolved locally as '$base_ref')"
    fi
  fi

  local merge_base
  merge_base="$(git -C "$repo" merge-base HEAD "$base_ref" 2>/dev/null)" \
    || die "review: failed to determine merge base against '$base_ref'"

  # Uniquify the findings filename like child_log_path does. ts_compact() is
  # second-resolution, so two parallel reviews started in the same second
  # would otherwise clobber each other's findings. Append the repo basename
  # (human-readable) plus PID and a random token for collision resistance.
  local out_path="$CEREBRO_SESSION_DIR/children/codex-$(ts_compact)-$(basename "$repo")-$$-${RANDOM}.md"
  local err_path="${out_path%.md}.err"

  say "cerebro: reviewing $repo against $base_description (merge-base $merge_base)"
  log_event "review_started" "repo=$repo base=$base_ref merge_base=$merge_base resume=${prior:-none}"

  # Short, focused prompt borrowed from aminmarashi/dev-tools `review`. We give
  # codex the merge base directly so it runs the right `git diff` itself
  # instead of guessing or pre-loading a huge patch into context.
  local codex_prompt
  codex_prompt="Review the code changes against the $base_description. The merge base commit for this comparison is $merge_base. Run \`git diff $merge_base\` to inspect the changes included since that merge base. Provide prioritized, actionable findings: bugs, regressions, security issues, missing tests, and correctness problems. Skip style nits, speculative concerns, and over-engineering suggestions (gold-plating, defensive code for cases that cannot occur, premature abstraction, or broad rewrites where a small fix would do); prefer the smallest change that resolves a real problem. For each finding, give a one-line title, the file or area affected, and a sentence explaining the concern and a suggested fix. Output Markdown only; no preamble."

  # When the orchestrator supplies the plan via --criteria-file, make codex
  # also act as the checkpoint gate: verify the change against EACH
  # acceptance criterion and end with a single machine-readable verdict line
  # the orchestrator keys its advance/retry decision on.
  if [[ -n "$criteria_block" ]]; then
    codex_prompt+=" This change is meant to implement the plan below, which ends with an acceptance-criteria checkpoint. After your findings, add a section headed '## Acceptance criteria' that checks the actual implemented diff against EACH criterion in the plan: list every criterion with a verdict of MET, PARTIAL, or NOT MET and a one-line justification grounded in the diff. Then output, as the VERY LAST line, exactly 'ACCEPTANCE CRITERIA: MET' if and only if every criterion is fully and correctly met, otherwise exactly 'ACCEPTANCE CRITERIA: NOT MET'. Do not soften a PARTIAL or unmet criterion into MET. The plan follows between the markers.
<plan>
$criteria_block
</plan>"
  fi

  # Run with --json so codex streams JSONL events on stdout (the only place it
  # exposes the resumable thread_id), and -o writes the human-readable findings
  # to out_path. We capture the event stream to json_path to pull thread_id out
  # of the first 'thread.started' event.
  local codex_opts=(exec --json --sandbox read-only --skip-git-repo-check \
                    --cd "$repo" -o "$out_path")
  [[ -n "$CEREBRO_REVIEW_MODEL" ]] && codex_opts+=(--model "$CEREBRO_REVIEW_MODEL")
  local json_path; json_path="$(mktemp)"

  # codex options precede the optional `resume <id>` subcommand; the prompt is
  # always the trailing positional.
  local rc run_args
  if [[ -n "$prior" ]]; then
    run_args=("${codex_opts[@]}" resume "$prior" "$codex_prompt")
  else
    run_args=("${codex_opts[@]}" "$codex_prompt")
  fi
  # Mark the review in-flight (preserving any prior thread we are resuming)
  # before it launches; PY_CODEX_CAPTURE tees the stream to json_path AND
  # persists the thread_id the instant codex emits it, so an interrupt mid
  # run leaves a resumable record.
  child_store_begin "$ckey" codex review "$repo" "${review_branch:-auto}" "$out_path"
  env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
    "${TIMEOUT_CMD[@]}" "$CEREBRO_CODEX_CMD" "${run_args[@]}" 2> "$err_path" \
    | python3 -c "$PY_CODEX_CAPTURE" "$json_path" "$store_file" "$ckey"
  rc=${PIPESTATUS[0]}

  # Stale fallback: a resume can be rejected up front because codex GC'd or no
  # longer recognizes the stored rollout -- the run then fails before emitting
  # any 'thread.started' event. Retry once fresh ONLY in that early-rejection
  # case. A resumed run that already streamed events (thread.started present)
  # and then failed is a real failure and surfaces below; we do not re-run it.
  if [[ -n "$prior" ]] && (( rc != 0 )) \
     && ! grep -q '"type":"thread.started"' "$json_path"; then
    log_event "review_resume_failed" "rc=$rc resume=$prior; retrying fresh"
    warn "review: resume of $prior failed (rc=$rc); retrying without resume"
    : > "$json_path"
    env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
      "${TIMEOUT_CMD[@]}" "$CEREBRO_CODEX_CMD" "${codex_opts[@]}" "$codex_prompt" 2> "$err_path" \
      | python3 -c "$PY_CODEX_CAPTURE" "$json_path" "$store_file" "$ckey"
    rc=${PIPESTATUS[0]}
  fi

  # On any failure -- non-zero exit OR empty output -- preserve the err log
  # but do NOT echo a findings path. The orchestrator must not feed a failed
  # review's stderr into apply-review as if it were findings.
  if (( rc != 0 )) || [[ ! -s "$out_path" ]]; then
    rm -f "$json_path"
    log_event "review_failed" "rc=$rc err=$err_path out=$out_path"
    warn "codex exited rc=$rc"
    [[ -s "$err_path" ]] && warn "see error log: $err_path"
    [[ -s "$out_path" ]] && warn "partial output preserved at: $out_path"
    die "review: codex run failed; not echoing a findings path"
  fi

  # The codex thread id was already persisted when PY_CODEX_CAPTURE saw the
  # first 'thread.started' event (so an interrupted review stays resumable);
  # just mark this review cleanly finished.
  child_store_done "$ckey"
  rm -f "$json_path"

  # Codex's exit was zero and out_path has content; treat that as findings.
  # Drop the (likely empty) err file to keep the children dir tidy.
  [[ -s "$err_path" ]] || rm -f "$err_path"

  # Record the HEAD we just reviewed. The next `cerebro review` (without
  # --base) will diff against this SHA so codex only sees what
  # apply-review changed, not the full PR diff again.
  local current_sha current_branch
  current_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
  current_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [[ -n "$current_sha" && -n "$current_branch" ]]; then
    mkdir -p "$state_dir"
    jq -n --arg repo "$canonical_repo" --arg branch "$current_branch" \
          --arg sha "$current_sha" --arg ts "$(ts_iso)" \
          --arg findings "$out_path" \
          '{repo:$repo, branch:$branch, last_reviewed_sha:$sha, last_findings:$findings, ts:$ts}' \
          > "$state_file" 2>/dev/null || true
  fi

  log_event "review_finished" "$out_path"
  echo "$out_path"
}

# ----- subcommand: cerebro apply-review <repo> <findings> [--notes ...] ----

cmd_apply_review() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local findings=""
  local prompt_text=""
  local notes=""
  local saw_prompt=0
  local pair=0
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    findings="$1"; shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt) saw_prompt=1; shift; prompt_text="${1:-}"; shift || true ;;
      --notes)  shift; notes="${1:-}";                     shift || true ;;
      --pair)   pair=1; shift ;;
      *) die "apply-review: unknown arg: $1" ;;
    esac
  done
  # An explicitly-passed --prompt must carry a non-empty operand. Without
  # this guard, `--prompt` with no value (or `--prompt ""`) leaves
  # prompt_text empty and would slip into the default-findings fallback
  # below, silently running a mutating apply-review the caller never asked
  # for. Treat it as a usage error instead.
  if (( saw_prompt )) && [[ -z "$prompt_text" ]]; then
    die "apply-review: --prompt requires a non-empty value"
  fi
  [[ -n "$repo" ]] \
    || die "usage: cerebro apply-review <repo-abs-path> (<findings-path> [--notes \"...\"] | --prompt \"<text>\")"
  [[ "$repo" = /* ]] || die "apply-review: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "apply-review: repo not a directory: $repo"

  # Default findings: when neither a findings path nor --prompt is given,
  # fall back to the last review's findings for this repo+branch so the
  # orchestrator cannot pass a guessed/stale name. Gate on saw_prompt too:
  # a genuinely-omitted --prompt may default, an explicitly-passed one
  # (already validated non-empty above) never silently falls back.
  if [[ -z "$findings" && -z "$prompt_text" ]] && (( ! saw_prompt )); then
    local rk sf
    rk="$(repo_state_key "$repo" 2>/dev/null)" || true
    sf="$CEREBRO_SESSION_DIR/review-state/$rk.json"
    local cur_branch
    cur_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [[ -n "$rk" && -r "$sf" ]]; then
      local lf lb
      lf="$(jq -r '.last_findings // empty' "$sf" 2>/dev/null)"
      lb="$(jq -r '.branch // empty'        "$sf" 2>/dev/null)"
      if [[ -n "$lf" && "$lb" == "$cur_branch" && -s "$lf" ]]; then
        findings="$lf"
        say "cerebro: apply-review defaulting to last review findings: $findings"
      fi
    fi
    [[ -n "$findings" ]] || die "apply-review: no findings path given and no prior review for this repo+branch in this session; run 'cerebro review $repo' first, or pass --prompt \"<text>\""
  fi

  if [[ -n "$findings" && -n "$prompt_text" ]]; then
    die "apply-review: pass either <findings-path> or --prompt, not both"
  fi
  if [[ -z "$findings" && -z "$prompt_text" ]]; then
    die "apply-review: requires <findings-path> or --prompt \"<text>\""
  fi
  if [[ -n "$prompt_text" && -n "$notes" ]]; then
    die "apply-review: --notes is only meaningful with a findings file; bake the context into --prompt instead"
  fi
  if [[ -n "$findings" ]]; then
    # Existence + staleness check. die (exit 1) on a bad path, naming the
    # correct last-review path when we know it; warn (non-fatal) when the
    # caller passed a valid-but-older findings file.
    local rk sf lf="" lb="" cur_branch
    rk="$(repo_state_key "$repo" 2>/dev/null)" || true
    sf="$CEREBRO_SESSION_DIR/review-state/$rk.json"
    cur_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    # Only treat .last_findings as "latest for this repo+branch" when the
    # stored branch matches the current branch -- same guard as the
    # default-findings path. Otherwise a post-branch-switch state file would
    # name another branch's findings as this branch's latest.
    if [[ -n "$rk" && -r "$sf" ]]; then
      lb="$(jq -r '.branch // empty' "$sf" 2>/dev/null)"
      if [[ -n "$lb" && "$lb" == "$cur_branch" ]]; then
        lf="$(jq -r '.last_findings // empty' "$sf" 2>/dev/null)"
      fi
    fi
    if [[ ! -r "$findings" || ! -s "$findings" ]]; then
      if [[ -n "$lf" && -s "$lf" ]]; then
        die "apply-review: findings not readable/empty: $findings (the last review for this repo+branch is: $lf)"
      fi
      die "apply-review: findings not readable/empty: $findings"
    fi
    if [[ -n "$lf" && "$lf" != "$findings" ]]; then
      warn "apply-review: '$findings' is not the latest review for this repo+branch (latest: $lf)"
    fi
  fi

  local child_log; child_log="$(child_log_path apply-review)"

  local sys_prompt
  sys_prompt='You are doing follow-up work on the current branch of a git
repository to update an open pull request. Read AGENTS.md at the repo
root first and follow it for commit format and project guardrails. Do
NOT modify AGENTS.md or CLAUDE.md. Stay on the current branch -- do
not create a new one. Apply the work described in the prompt body
(either reviewer findings the orchestrator scoped, or a direct fix
instruction). Skip nits and style-only items unless explicitly called
out. Run the repo'\''s test or type-check command if one is obvious.
Commit per AGENTS.md and push so the existing PR updates in place.'

  # Child-session continuity: apply-review stays on the current branch, so we
  # key on repo+role+branch. Repeated apply-reviews on the same PR branch
  # resume the same conversation -- and an apply-review INTERRUPTED mid-run
  # resumes its half-applied work instead of starting over.
  local store_file; store_file="$(child_sessions_file)"
  local ar_branch; ar_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  local ckey prior=""
  ckey="$(child_key "$repo" apply-review "${ar_branch:-default}")"
  if prior="$(child_session_get "$ckey")" && [[ -n "$prior" ]] && child_session_fresh "$ckey"; then
    :
  else
    prior=""
  fi

  if [[ -n "$findings" ]]; then
    say "cerebro: applying review fixes in $repo"
    log_event "apply_review_started" "findings=$findings resume=${prior:-none}"
  else
    say "cerebro: applying inline fix in $repo"
    log_event "apply_review_started" "prompt=inline resume=${prior:-none}"
  fi

  local opts=(-p --permission-mode bypassPermissions
              --allowedTools "Read Edit Write Bash Grep Glob WebSearch WebFetch mcp__playwright__*"
              --output-format stream-json --verbose
              --append-system-prompt "$sys_prompt")
  [[ -n "$CEREBRO_MODEL" ]] && opts+=(--model "$CEREBRO_MODEL")

  local PAIR_SID="" PAIR_OPTS=() PAIR_FIFO="" PAIR_STEER="" PAIR_IDLE=""
  if (( pair )); then
    pair_begin apply-review "$repo" "$ar_branch" "$child_log" "$prior"
    opts+=("${PAIR_OPTS[@]}")
  fi

  local child_prompt
  child_prompt="$(
    if [[ -n "$findings" ]]; then
      printf 'Apply the following review findings on the current branch. Commit and push so the existing PR updates.\n\n<orchestrator-notes>\n%s\n</orchestrator-notes>\n\n<findings>\n' "$notes"
      cat "$findings"
      printf '\n</findings>\n'
    else
      printf 'Apply the following fix on the current branch. Commit and push so the existing PR updates.\n\n<task>\n%s\n</task>\n' "$prompt_text"
    fi
  )"

  local rc id_capture; id_capture="$(mktemp)"
  local run_opts=("${opts[@]}")
  [[ -n "$prior" ]] && run_opts+=(--resume "$prior")
  child_store_begin "$ckey" claude apply-review "$repo" "${ar_branch:-default}" "$child_log"
  ( cd "$repo" && printf '%s' "$child_prompt" \
      | pair_feed "$pair" "$PAIR_FIFO" "$PAIR_STEER" "$child_log" "$PAIR_IDLE" \
      | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
        "${TIMEOUT_CMD[@]}" claude "${run_opts[@]}" 2>/dev/null \
      | tee "$child_log" \
      | python3 -c "$PY_PARSE_STREAM" "" "$id_capture" "$store_file" "$ckey" )
  rc=$?
  pair_cleanup "$pair"

  # Stale fallback (same rule as execute): only retry fresh when the resumed
  # run never started -- no init event, so id_capture is empty and nothing was
  # mutated. A resume that started then failed is fatal (handled below); a
  # fresh re-run would duplicate the work it already applied.
  if (( rc != 0 )) && [[ -n "$prior" ]] && [[ ! -s "$id_capture" ]]; then
    log_event "apply_review_resume_failed" "rc=$rc resume=$prior; retrying fresh"
    warn "apply-review: resume of $prior failed (rc=$rc); retrying without resume"
    : > "$id_capture"
    local retry_opts=("${opts[@]}")
    if (( pair )); then
      pair_begin apply-review "$repo" "$ar_branch" "$child_log" ""
      retry_opts+=("${PAIR_OPTS[@]}")
    fi
    ( cd "$repo" && printf '%s' "$child_prompt" \
        | pair_feed "$pair" "$PAIR_FIFO" "$PAIR_STEER" "$child_log" "$PAIR_IDLE" \
        | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
          "${TIMEOUT_CMD[@]}" claude "${retry_opts[@]}" 2>/dev/null \
        | tee "$child_log" \
        | python3 -c "$PY_PARSE_STREAM" "" "$id_capture" "$store_file" "$ckey" )
    rc=$?
    pair_cleanup "$pair"
  fi

  if (( rc != 0 )); then
    rm -f "$id_capture"
    log_event "apply_review_failed" "rc=$rc log=$child_log"
    die "apply-review: child claude failed (rc=$rc); see $child_log"
  fi
  child_store_done "$ckey"
  rm -f "$id_capture"
  log_event "apply_review_finished" "$child_log"
  pair_report "$pair" "$child_log"
  echo "$child_log"
}

