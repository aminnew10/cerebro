# cerebro lib: commands/plan
# subcommands: plan / plans
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro plan "<plan markdown>" [--out <name>] ------------
# The orchestrator drafts plans ITSELF (it holds the full conversation
# context and the read-only bridges); it has no Write tool, so this is its
# way to record a plan it composed -- the same pattern as `cerebro spec set`
# and `cerebro learn-set`. Re-running with the same --out OVERWRITES the
# file, which is how plan revisions stay the source of truth.

cmd_plan() {
  require_session

  local content="${1:-}"; shift || true
  local out_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) shift; out_name="${1:-}"; shift || true ;;
      *) die "plan: unknown arg: $1" ;;
    esac
  done
  [[ -n "${content//[[:space:]]/}" ]] \
    || die "usage: cerebro plan \"<plan markdown>\" [--out <name>]"

  local plans_dir="$CEREBRO_SESSION_DIR/plans"
  mkdir -p "$plans_dir"

  if [[ -z "$out_name" ]]; then
    local n=1
    while [[ -e "$plans_dir/plan-$n.md" ]]; do n=$((n+1)); done
    out_name="plan-$n"
  fi
  out_name="${out_name%.md}"
  local out_path="$plans_dir/$out_name.md"

  printf '%s\n' "$content" > "$out_path" || die "plan: cannot write $out_path"
  log_event "plan_written" "$out_path"
  say "cerebro: recorded plan ($out_path, ${#content} chars)"
  echo "$out_path"
}

# ----- subcommand: cerebro plans [rm <name>] --------------------------------
# List the session's plan files, or remove one -- the orchestrator drops a
# plan from a suite when a mid-flight revision makes a step obsolete, so the
# stale file cannot be listed or executed later. Removal is confined to this
# session's plans dir: the argument is reduced to its basename.

cmd_plans() {
  require_session
  local plans_dir="$CEREBRO_SESSION_DIR/plans"
  if [[ "${1:-}" == "rm" ]]; then
    shift
    local name="${1:-}"
    [[ -n "$name" ]] || die "usage: cerebro plans rm <name>"
    name="$(basename "${name%.md}")"
    local f="$plans_dir/$name.md"
    [[ -f "$f" ]] || die "plans rm: no such plan: $f"
    rm -f "$f" || die "plans rm: cannot remove $f"
    log_event "plan_removed" "$f"
    say "cerebro: removed plan ($f)"
    return 0
  fi
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
