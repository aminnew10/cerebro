# cerebro lib: commands/plan
# subcommands: plan / plans
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro plan <repo> "<desc>" [--out <name>] -------------

cmd_plan() {
  require_session
  build_timeout_cmd

  local repo="${1:-}"; shift || true
  local desc="${1:-}"; shift || true
  local out_name=""
  local pair=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) shift; out_name="${1:-}"; shift || true ;;
      --pair) pair=1; shift ;;
      *) die "plan: unknown arg: $1" ;;
    esac
  done
  [[ -n "$repo" && -n "$desc" ]] || die "usage: cerebro plan <repo-abs-path> \"<description>\" [--out <name>]"
  [[ "$repo" = /* ]] || die "plan: repo path must be absolute: $repo"
  [[ -d "$repo" ]] || die "plan: repo not a directory: $repo"

  local plans_dir="$CEREBRO_SESSION_DIR/plans"
  mkdir -p "$plans_dir"

  if [[ -z "$out_name" ]]; then
    local n=1
    while [[ -e "$plans_dir/plan-$n.md" ]]; do n=$((n+1)); done
    out_name="plan-$n"
  fi
  out_name="${out_name%.md}"
  local out_path="$plans_dir/$out_name.md"
  local child_log="$CEREBRO_SESSION_DIR/children/plan-$(ts_compact).jsonl"

  local sys_prompt
  sys_prompt='You are drafting an implementation plan for a developer. Look up
the codebase you have read access to and produce a Markdown plan that
another engineer (or another claude session) can execute. Keep paths,
function names, and file names concrete -- this is a working plan, not
an offline-reading rewrite. Work like a lazy senior engineer: keep it
SIMPLE. Plan the smallest change that satisfies the request -- no scope
creep, no gold-plating, no future-proofing nobody asked for. The plan
describes only the work itself; do not mention branches, PRs, or other
orchestration mechanics. Begin your reply with a Markdown H1 title.
Do not add a preamble before the title. Do not wrap your output in an
outer code fence. Output ONLY the plan.'

  say "cerebro: planning in $repo -> $out_path"
  log_event "plan_started" "$out_path"

  local opts=(-p --permission-mode bypassPermissions --allowedTools "Read Grep Glob WebSearch WebFetch mcp__playwright__*"
              --output-format stream-json --verbose
              --append-system-prompt "$sys_prompt")
  [[ -n "$CEREBRO_MODEL" ]] && opts+=(--model "$CEREBRO_MODEL")

  local PAIR_SID="" PAIR_OPTS=() PAIR_FIFO="" PAIR_STEER="" PAIR_IDLE=""
  if (( pair )); then
    pair_begin plan "$repo" "" "$child_log"
    opts+=("${PAIR_OPTS[@]}")
  fi

  local prompt
  prompt="Write an implementation plan for the following request, exploring this repository with your read tools as needed.

<request>
$desc
</request>"

  local rc
  ( cd "$repo" && \
    printf '%s' "$prompt" \
      | pair_feed "$pair" "$PAIR_FIFO" "$PAIR_STEER" "$child_log" "$PAIR_IDLE" \
      | env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
        "${TIMEOUT_CMD[@]}" claude "${opts[@]}" 2>/dev/null \
      | tee "$child_log" \
      | python3 -c "$PY_PARSE_STREAM" "$out_path" )
  rc=$?
  pair_cleanup "$pair"

  if (( rc != 0 )); then
    log_event "plan_failed" "rc=$rc"
    die "plan: child claude failed (rc=$rc); see $child_log"
  fi

  log_event "plan_written" "$out_path"
  pair_report "$pair" "$child_log"
  echo "$out_path"
}

# ----- subcommand: cerebro plans -------------------------------------------

cmd_plans() {
  require_session
  local plans_dir="$CEREBRO_SESSION_DIR/plans"
  if [[ ! -d "$plans_dir" ]] || [[ -z "$(ls -A "$plans_dir" 2>/dev/null)" ]]; then
    echo "cerebro: no plans in this session"
    return 0
  fi
  # ls -lt is portable enough; print mtime + filename.
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local mtime
    mtime="$(python3 -c 'import os,sys,datetime; print(datetime.datetime.utcfromtimestamp(os.path.getmtime(sys.argv[1])).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$f")"
    printf '%s  %s\n' "$mtime" "$f"
  done < <(find "$plans_dir" -maxdepth 1 -type f -name '*.md' | sort)
}

