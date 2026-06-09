# cerebro lib: commands/spec
# subcommand: spec (set / history)
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommands: the session spec (requirements of record) ---------------
# spec.md holds the CURRENT authoritative specification + requirements for the
# session; spec-history.jsonl is an append-only log of every version ever set
# (one {ts,text} object per line, oldest first). The newest history entry
# always equals spec.md. Both are per-session files the orchestrator can Read
# directly, so the requirements survive a context compaction. The orchestrator
# has no Write tool, so `spec set` is its only way to record them.

spec_file()         { printf '%s\n' "$CEREBRO_SESSION_DIR/spec.md"; }
spec_history_file() { printf '%s\n' "$CEREBRO_SESSION_DIR/spec-history.jsonl"; }

# cerebro spec [set "<text>" | history]
#   (no action)  -- print the current spec + a count of historical versions
#   set "<text>" -- replace the current spec, archiving the new version to the
#                   append-only history first so the full evolution is kept
#   history      -- print every recorded version, oldest first, with timestamps
cmd_spec() {
  require_session
  case "${1:-show}" in
    set)     shift; spec_set "$@" ;;
    history) shift; spec_history ;;
    show)    spec_show ;;
    *) die "usage: cerebro spec [set \"<specification and requirements>\" | history]" ;;
  esac
}

spec_set() {
  local text="${*:-}"
  [[ -n "${text//[[:space:]]/}" ]] || die "usage: cerebro spec set \"<specification and requirements>\""
  local sf hf ts
  sf="$(spec_file)"; hf="$(spec_history_file)"
  ts="$(ts_iso)"
  # Defense-in-depth for rule 9: when REPLACING an existing non-empty spec,
  # surface the current spec head plus a reminder that switching to a
  # DIFFERENT task mid-flight is not allowed. Advisory only -- it never
  # blocks and never alters the record/archive flow below. First-ever set
  # (empty/absent spec) and same-task refinement see only this note.
  if [[ -s "$sf" ]]; then
    {
      printf 'cerebro: WARNING -- replacing the current session spec. If this is a DIFFERENT task, do not switch unless the current task is complete or the user asked; refining the same task is fine.\n'
      printf 'cerebro: current spec (head):\n'
      head -c 200 "$sf" | sed 's/^/    /'
      printf '\n'
    } >&2
  fi
  jq -nc --arg ts "$ts" --arg text "$text" '{ts:$ts, text:$text}' \
    >> "$hf" || die "spec set: cannot write history ($hf)"
  printf '%s\n' "$text" > "$sf" || die "spec set: cannot write spec ($sf)"
  log_event "spec_set" "chars=${#text}"
  say "cerebro: recorded session spec ($sf, ${#text} chars; history: $hf)"
}

spec_show() {
  local sf hf
  sf="$(spec_file)"; hf="$(spec_history_file)"
  if [[ -s "$sf" ]]; then
    cat "$sf"
    local n=0
    [[ -f "$hf" ]] && n="$(grep -c '' "$hf" 2>/dev/null || printf 0)"
    echo
    echo "--- current session spec: $sf"
    echo "--- history: ${n} version(s) recorded ($hf)"
  else
    echo "cerebro: no session spec recorded yet ($sf)"
    echo "Record one with: cerebro spec set \"<specification and requirements>\""
  fi
}

spec_history() {
  local hf; hf="$(spec_history_file)"
  if [[ ! -s "$hf" ]]; then
    echo "cerebro: no session spec history yet ($hf)"
    return 0
  fi
  python3 - "$hf" <<'PY'
import json, sys
path = sys.argv[1]
n = 0
with open(path) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        n += 1
        print(f"=== version {n}  [{rec.get('ts', '?')}] ===")
        print(rec.get("text", ""))
        print()
print(f"--- {n} version(s) total ---")
PY
}

