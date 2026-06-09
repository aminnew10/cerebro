# cerebro lib: commands/learn
# subcommands: learn-note / learn-set / learnings
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommands: learning the user's preferences ------------------------
# learnings.md (active) and pending-learnings.md (a single append-only signal
# journal) are GLOBAL under $CEREBRO_HOME, so general preferences persist
# across every session and repo. The orchestrator has no write tools, so these
# subcommands are its only way to record what it observes and promote it.

# Max chars in the active learnings.md. It is injected verbatim into the
# orchestrator's system prompt, so it must stay system-message-sized.
CEREBRO_LEARN_CAP="${CEREBRO_LEARN_CAP:-1600}"

# cerebro learn-note "<observation>"
# Append one preference signal (direct or indirect) to the pending journal.
cmd_learn_note() {
  require_session
  local text="${*:-}"
  [[ -n "${text//[[:space:]]/}" ]] || die "usage: cerebro learn-note \"<observation>\""
  local f; f="$(pending_learnings_file)"
  if [[ ! -f "$f" ]]; then
    printf '# Pending learnings\n\nObserved preference signals awaiting confirmation -- one signal per line.\nPromote a signal to active learnings (cerebro learn-set) only once the\nevidence here is clear and repeated; when unsure, ask the user first.\n\n' > "$f"
  fi
  printf -- '- [%s] %s\n' "$(ts_iso)" "$text" >> "$f"
  log_event "learn_note" "$text"
  say "cerebro: recorded a pending preference signal ($f)"
}

# cerebro learn-set "<consolidated learnings>"
# Replace the active learnings with a consolidated set the orchestrator
# composed after reviewing clear evidence in the pending journal. Capped so it
# stays small enough for the system message.
cmd_learn_set() {
  require_session
  local text="${*:-}"
  [[ -n "${text//[[:space:]]/}" ]] || die "usage: cerebro learn-set \"<consolidated learnings>\""
  local n=${#text}
  if (( n > CEREBRO_LEARN_CAP )); then
    die "learn-set: too large (${n} chars > ${CEREBRO_LEARN_CAP}). Active learnings are injected into the orchestrator system prompt -- consolidate to a few short, general bullets."
  fi
  local f; f="$(learnings_file)"
  printf '%s\n' "$text" > "$f"
  log_event "learn_set" "chars=$n"
  say "cerebro: updated active learnings ($f, ${n} chars)"
}

# cerebro learnings
# Show the active learnings plus a count of pending signals.
cmd_learnings() {
  require_session
  local active pending
  active="$(learnings_file)"; pending="$(pending_learnings_file)"
  echo "active learnings: $active"
  if [[ -s "$active" ]]; then
    sed 's/^/  /' "$active"
  else
    echo "  (none yet)"
  fi
  echo
  echo "pending signals:  $pending"
  if [[ -s "$pending" ]]; then
    local c; c="$(grep -c '^- \[' "$pending" 2>/dev/null || true)"
    echo "  (${c:-0} signal(s) recorded; Read the file to review the evidence)"
  else
    echo "  (none yet)"
  fi
}

