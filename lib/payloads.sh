# cerebro lib: payloads
# loaders for the on-disk payloads under lib/payloads/: hook script,
# settings.json, orchestrator system prompt, child role prompts, default
# templates. The files live beside the code (resolved via CEREBRO_LIB_DIR),
# so a `git pull` updates them and materialise_home() copies the
# home-resident ones into $CEREBRO_HOME on next launch.
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- payload loaders -------------------------------------------------------

cerebro_payloads_dir() { printf '%s\n' "$CEREBRO_LIB_DIR/payloads"; }

cerebro_hook_script() { cat "$(cerebro_payloads_dir)/hook.sh"; }

# cerebro_settings_json <hook-path> -- the .claude/settings.local.json that
# registers the UserPromptSubmit hook. The template carries a
# __CEREBRO_HOOK_PATH__ placeholder; substitute it with bash expansion so any
# character in the path is inert.
cerebro_settings_json() {
  local hook_path="$1" tpl
  tpl="$(cat "$(cerebro_payloads_dir)/settings.json")"
  printf '%s\n' "${tpl//__CEREBRO_HOOK_PATH__/$hook_path}"
}

cerebro_system_prompt() { cat "$(cerebro_payloads_dir)/system-prompt.md"; }

# ----- child agent prompts --------------------------------------------------
# Each spawned child (plan / execute / apply-review / doc-write) runs as a
# non-interactive `claude -p`. Its role base prompt lives at
# lib/payloads/prompts/<role>.md and the shared non-interactive note beside
# them, so a single source feeds both the original command and `cerebro
# answer` (which resumes the same child and must re-pass the identical system
# prompt to keep the child's role constraints intact).

# The note every child shares: it cannot ask questions interactively, but it
# may pause by exiting with its question as its final message for cerebro to
# answer and resume.
child_noninteractive_note() {
  cat "$(cerebro_payloads_dir)/prompts/noninteractive-note.md"
}

# child_sys_prompt <role> -- the full --append-system-prompt for a child of the
# given role: its role base prompt followed by the shared non-interactive note.
child_sys_prompt() {
  local role="$1"
  local f="$(cerebro_payloads_dir)/prompts/$role.md"
  case "$role" in
    plan|execute|apply-review|doc-write) ;;
    *) die "child_sys_prompt: unknown role: $role" ;;
  esac
  printf '%s\n\n%s' "$(cat "$f")" "$(child_noninteractive_note)"
}

# child_allowed_tools <role> -- the --allowedTools list for a child of the
# given role. plan is read-only; the mutating roles also get Edit/Write/Bash.
child_allowed_tools() {
  case "$1" in
    plan) printf 'Read Grep Glob WebSearch WebFetch mcp__playwright__*' ;;
    execute|apply-review|doc-write)
      printf 'Read Edit Write Bash Grep Glob WebSearch WebFetch mcp__playwright__*' ;;
    *) die "child_allowed_tools: unknown role: $1" ;;
  esac
}

# Default AGENTS.md / CLAUDE.md that `cerebro execute` drops into a repo
# that doesn't already have them. These are not authoritative rules baked
# into cerebro -- they are templates the user can edit at
# `$CEREBRO_HOME/templates/AGENTS.md`. Once written, cerebro never
# overwrites them.

cerebro_default_agents_md() { cat "$(cerebro_payloads_dir)/templates/AGENTS.md"; }

cerebro_default_claude_md() { cat "$(cerebro_payloads_dir)/templates/CLAUDE.md"; }
