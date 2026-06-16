# cerebro lib: payloads
# loaders for the on-disk payloads under lib/payloads/: opencode agent
# definitions, the session-binding plugin, opencode config, orchestrator system
# prompt, child role prompts, default templates. The files live beside the code
# (resolved via CEREBRO_LIB_DIR), so a `git pull` updates them and
# materialise_home() copies the home-resident ones into
# $CEREBRO_HOME/.opencode on next launch.
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- payload loaders -------------------------------------------------------

cerebro_payloads_dir() { printf '%s\n' "$CEREBRO_LIB_DIR/payloads"; }

# The session-binding plugin: a small opencode plugin that records the
# opencode-assigned session id into the active cerebro session's metadata (so
# `cerebro --resume` can re-open the same opencode conversation) and appends
# each user prompt to the session transcript (so observers can narrate the
# orchestrator track). It keys off the CEREBRO_SESSION_DIR env var that cerebro
# exports into every interactive opencode process it launches.
cerebro_plugin_js() { cat "$(cerebro_payloads_dir)/plugin/cerebro.js"; }

# The opencode config cerebro layers on top of the user's global config for
# every cerebro-launched opencode process. Keeps child runs deterministic
# (no autoshare, no autoupdate mid-run).
cerebro_opencode_json() { cat "$(cerebro_payloads_dir)/opencode.json"; }

cerebro_system_prompt() { cat "$(cerebro_payloads_dir)/system-prompt.md"; }

# The observe-mode overlay appended after the orchestrator prompt when a
# session is launched with `cerebro --observe`: it narrows the session to
# watching and steering live paired children and forbids direct changes.
cerebro_observe_mode_prompt() { cat "$(cerebro_payloads_dir)/observe-mode.md"; }

# Runtime note shared by the read-only opencode reviewer/auditor children.
cerebro_reviewer_note() {
  cat "$(cerebro_payloads_dir)/prompts/reviewer-note.md"
}

# The plan-audit prompt fed to the read-only reviewer child spawned by
# `cerebro audit` (the plan / spec / context blocks are appended after it). The
# read-only constraints live in the agent, so this is just the audit task.
cerebro_audit_prompt() {
  local out; out="$(printf '%s\n\n%s' \
    "$(cerebro_reviewer_note)" \
    "$(cat "$(cerebro_payloads_dir)/prompts/audit.md")")"
  local ov; ov="$(overlay_body grader)"
  [[ -n "$ov" ]] && out="$(printf '%s\n\n# Local grader overlay\n%s' "$out" "$ov")"
  printf '%s\n' "$out"
}

# The hill-climbing analysis prompt fed to the read-only reviewer child
# spawned by `cerebro improve` (the trace-corpus locations / context are
# appended after it). Mirrors cerebro_audit_prompt.
cerebro_improve_prompt() {
  printf '%s\n\n%s\n' \
    "$(cerebro_reviewer_note)" \
    "$(cat "$(cerebro_payloads_dir)/prompts/improve.md")"
}

# ----- opencode agents ------------------------------------------------------
# Every spawned child (execute / apply-review / doc-write) runs as a
# non-interactive `opencode run --agent cerebro-<role>`. The agent's role
# prompt and tool permissions live in an opencode agent markdown file under
# $CEREBRO_HOME/.opencode/agent/. We GENERATE those files from the role base
# prompt (lib/payloads/prompts/<role>.md) plus the shared non-interactive note,
# wrapped in opencode frontmatter that pins the agent's permissions. Because the
# role lives in the agent file, `cerebro answer` (which resumes the same child)
# re-selects the same agent by name and inherits the identical role constraints
# with no per-call prompt plumbing.

# The note every child shares: it cannot ask questions interactively, but it
# may pause by ending its run with its question as its final message for cerebro
# to answer and resume.
child_noninteractive_note() {
  cat "$(cerebro_payloads_dir)/prompts/noninteractive-note.md"
}

# The opencode agent name for a child role (the basename of its agent file).
# review and audit share one read-only reviewer agent.
child_agent_name() {
  case "$1" in
    execute|apply-review|doc-write) printf 'cerebro-%s\n' "$1" ;;
    review|audit) printf 'cerebro-reviewer\n' ;;
    *) die "child_agent_name: unknown role: $1" ;;
  esac
}

# child_agent_file <role> -- the full opencode agent markdown for a child of the
# given role: YAML frontmatter pinning its mode + tool permissions, then its
# role base prompt followed by the shared non-interactive note. All child roles
# get full edit/bash/read/search access (they are the only place repo mutation
# happens); the read-only review/audit child runs on the cerebro-reviewer agent.
child_agent_file() {
  local role="$1"
  local f="$(cerebro_payloads_dir)/prompts/$role.md"
  local desc
  case "$role" in
    execute)      desc="cerebro execute child: implement a plan in an isolated worktree and open a PR" ;;
    apply-review) desc="cerebro apply-review child: apply review findings or a fix on the current branch" ;;
    doc-write)    desc="cerebro doc-write child: update user-facing docs for a shipped change" ;;
    *) die "child_agent_file: unknown role: $role" ;;
  esac
child_agent_file() {
  local role="$1"
  local f="$(cerebro_payloads_dir)/prompts/$role.md"
  local desc
  case "$role" in
    execute)      desc="cerebro execute child: implement a plan in an isolated worktree and open a PR" ;;
    apply-review) desc="cerebro apply-review child: apply review findings or a fix on the current branch" ;;
    doc-write)    desc="cerebro doc-write child: update user-facing docs for a shipped change" ;;
    *) die "child_agent_file: unknown role: $role" ;;
  esac
  local out
  out=$(cat <<EOF
---
description: $desc
mode: all
permission:
  edit: allow
  bash: allow
  webfetch: allow
  websearch: allow
  external_directory: allow
---
EOF
)
  out="$(printf '%s\n%s\n\n%s' "$out" "$(cat "$f")" "$(child_noninteractive_note)")"
  # Append the user-owned local overlay for this role, if any, so a user can
  # tune a child role prompt without forking. This feeds both the original
  # spawn and `cerebro answer` (which re-passes the identical system prompt).
  local ov; ov="$(overlay_body "$role")"
  [[ -n "$ov" ]] && out="$(printf '%s\n\n# Local overlay\n%s' "$out" "$ov")"
  printf '%s' "$out"
}
}

# reviewer_agent_file -- the opencode agent markdown for the read-only reviewer
# used by `cerebro review` and `cerebro audit`. It is clamped to genuine
# read-only operation: no edit/write/task, and bash is denied except the
# inspection commands a reviewer needs (git diff/log/show/..., grep/rg, cat,
# sed -n, find, ls, jq, ...). Its findings are the run's final message, captured
# by the calling command. Runs on CEREBRO_REVIEW_MODEL (a model independent of
# the implementer).
reviewer_agent_file() {
  cat <<'EOF'
---
description: cerebro reviewer/auditor: read-only, independent review of a diff or plan
mode: all
permission:
  edit: deny
  write: deny
  task: deny
  webfetch: deny
  websearch: deny
  external_directory: allow
  bash:
    "*": deny
    "git diff*": allow
    "git show*": allow
    "git log*": allow
    "git status*": allow
    "git rev-parse*": allow
    "git merge-base*": allow
    "git blame*": allow
    "git ls-files*": allow
    "git cat-file*": allow
    "grep *": allow
    "rg *": allow
    "cat *": allow
    "head *": allow
    "tail *": allow
    "sed -n*": allow
    "find *": allow
    "ls*": allow
    "wc *": allow
    "jq *": allow
    "test *": allow
---
EOF
  printf '%s\n' "$(cerebro_reviewer_note)"
}

# orchestrator_agent_file <body> -- the opencode agent markdown for the
# interactive orchestrator. Its tools are clamped so it can never touch a repo
# directly: no edit/write, no Task delegation (which would otherwise let it
# spawn a full-access build subagent around the sandbox), and bash is denied
# except `cerebro ...`. Read/grep/glob and web tools stay on (read-only
# exploration), and external_directory is allowed so it can read the repos the
# user names by absolute path. <body> is the composed system prompt
# (system-prompt.md plus any learned preferences).
orchestrator_agent_file() {
  local body="$1"
  cat <<'EOF'
---
description: cerebro orchestrator -- drives the plan/execute/review loop via cerebro subcommands
mode: primary
permission:
  edit: deny
  write: deny
  task: deny
  external_directory: allow
  bash:
    "*": deny
    "cerebro": allow
    "cerebro *": allow
---
EOF
  printf '%s\n' "$body"
}

# observer_agent_file <body> -- the opencode agent markdown for a
# `cerebro --observe` session. Same read-only clamp as the orchestrator, but
# bash is narrowed further to only the observe/steer/restart and read-only
# status commands, so a watcher session can never mutate a repo. <body> is the
# composed orchestrator prompt plus the observe-mode overlay.
observer_agent_file() {
  local body="$1"
  cat <<'EOF'
---
description: cerebro observer -- watch and steer another session's live paired children
mode: primary
permission:
  edit: deny
  write: deny
  task: deny
  external_directory: allow
  bash:
    "*": deny
    "cerebro observe": allow
    "cerebro observe *": allow
    "cerebro steer": allow
    "cerebro steer *": allow
    "cerebro restart": allow
    "cerebro restart *": allow
    "cerebro status": allow
    "cerebro status *": allow
    "cerebro list": allow
    "cerebro list *": allow
    "cerebro recall": allow
    "cerebro recall *": allow
    "cerebro spec": allow
    "cerebro spec *": allow
    "cerebro learnings": allow
    "cerebro learnings *": allow
---
EOF
  printf '%s\n' "$body"
}

# Default AGENTS.md that `cerebro execute` drops into a repo that doesn't
# already have one. This is not authoritative rules baked into cerebro -- it is
# a template the user can edit at `$CEREBRO_HOME/templates/AGENTS.md`. Once
# written, cerebro never overwrites it. opencode reads AGENTS.md as its project
# rules file, so a single AGENTS.md serves both cerebro and opencode.

cerebro_default_agents_md() { cat "$(cerebro_payloads_dir)/templates/AGENTS.md"; }
