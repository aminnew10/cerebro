# cerebro lib: commands/overlay
# subcommand: overlay (set / show / rm of user-owned harness overlays)
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro overlay set/show/rm <target> --------------------
# Overlays are user-owned plain-markdown files under $CEREBRO_HOME/overlays/,
# each APPENDED by a loader onto a shipped prompt/grader so a user can tune any
# prompt surface locally without forking (upgrade-safe: a `git pull` of the
# harness leaves them untouched). Mirrors learn.sh: the orchestrator has no
# Write tool, so these subcommands are its only way to author an overlay.
#
#   system        -> appended to the orchestrator system prompt
#   execute       -> appended to the execute child's role prompt
#   apply-review  -> appended to the apply-review child's role prompt
#   doc-write     -> appended to the doc-write child's role prompt
#   grader        -> appended to the codex audit AND review grader prompts

# The valid overlay targets, shared by the validation paths below.
CEREBRO_OVERLAY_TARGETS="system execute apply-review doc-write grader"

# overlay_target_ok <target> -- succeed when <target> is a known overlay.
overlay_target_ok() {
  local t
  for t in $CEREBRO_OVERLAY_TARGETS; do
    [[ "$1" == "$t" ]] && return 0
  done
  return 1
}

cmd_overlay() {
  require_session
  local action="${1:-}"; shift || true
  case "$action" in
    set)  cmd_overlay_set "$@" ;;
    show) cmd_overlay_show "$@" ;;
    rm)   cmd_overlay_rm "$@" ;;
    *) die "usage: cerebro overlay {set <target> \"<text>\" | show [<target>] | rm <target>}; targets: $CEREBRO_OVERLAY_TARGETS" ;;
  esac
}

cmd_overlay_set() {
  local target="${1:-}"; shift || true
  overlay_target_ok "$target" \
    || die "overlay set: unknown target '$target'; valid targets: $CEREBRO_OVERLAY_TARGETS"
  local text="${*:-}"
  [[ -n "${text//[[:space:]]/}" ]] || die "usage: cerebro overlay set $target \"<text>\""
  local n=${#text}
  if (( n > CEREBRO_OVERLAY_CAP )); then
    die "overlay set: too large (${n} chars > ${CEREBRO_OVERLAY_CAP}). Overlays are appended onto a shipped prompt -- keep them to a few focused additions."
  fi
  mkdir -p "$(overlays_dir)" || die "overlay set: cannot create $(overlays_dir)"
  local f; f="$(overlay_file "$target")"
  printf '%s\n' "$text" > "$f"
  log_event "overlay_set" "target=$target chars=$n"
  say "cerebro: updated overlay '$target' ($f, ${n} chars)"
}

cmd_overlay_show() {
  local target="${1:-}"
  if [[ -n "$target" ]]; then
    overlay_target_ok "$target" \
      || die "overlay show: unknown target '$target'; valid targets: $CEREBRO_OVERLAY_TARGETS"
    local f; f="$(overlay_file "$target")"
    if [[ -s "$f" ]]; then
      cat "$f"
    else
      echo "(none)"
    fi
    return 0
  fi
  # No target: list every overlay with present/absent + char count.
  echo "overlays dir: $(overlays_dir)"
  local t f n
  for t in $CEREBRO_OVERLAY_TARGETS; do
    f="$(overlay_file "$t")"
    if [[ -s "$f" ]]; then
      n=$(wc -c < "$f" | tr -d ' ')
      printf '  %-12s present (%s chars)\n' "$t" "$n"
    else
      printf '  %-12s absent\n' "$t"
    fi
  done
}

cmd_overlay_rm() {
  local target="${1:-}"
  overlay_target_ok "$target" \
    || die "overlay rm: unknown target '$target'; valid targets: $CEREBRO_OVERLAY_TARGETS"
  local f; f="$(overlay_file "$target")"
  if [[ -e "$f" ]]; then
    rm -f "$f"
    log_event "overlay_rm" "target=$target"
    say "cerebro: removed overlay '$target' ($f)"
  else
    say "cerebro: overlay '$target' was not set ($f)"
  fi
}
