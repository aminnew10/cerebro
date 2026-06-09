# cerebro lib: helpers
# small shared helpers: say/warn/die, error codes, path + repo resolution, usage
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- helpers --------------------------------------------------------------

say()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'cerebro: warning: %s\n' "$*" >&2; }
die()  { printf 'cerebro: error: %s\n' "$*" >&2; exit 1; }
dbg()  { [[ "$CEREBRO_DEBUG" == "1" ]] && printf 'cerebro: debug: %s\n' "$*" >&2; return 0; }

# Error helpers for the read-only bridge subcommands (git/gh/read/grep/ls).
# Exit codes are documented in the orchestrator's system prompt so the model
# can interpret them programmatically.
err_usage()  { printf 'cerebro: error: %s\n' "$*" >&2; exit 2; }
err_path()   { printf 'cerebro: error: %s\n' "$*" >&2; exit 3; }
err_subcmd() { printf 'cerebro: error: %s\n' "$*" >&2; exit 4; }
err_flag()   { printf 'cerebro: error: %s\n' "$*" >&2; exit 5; }
err_escape() { printf 'cerebro: error: %s\n' "$*" >&2; exit 6; }

# Benign "target does not exist / wrong type" outcome for the read-only
# EXPLORATION bridges (read/ls/grep). Default: print a machine-recognizable
# marker to stdout and exit 0, so a missing probe target during a parallel
# fan-out is a successful empty result, not a cascade-triggering failure.
# With strict=1 (--strict-missing), restore the old behavior: stderr + exit 3.
#   $1 = strict (0|1)   $2 = marker (stdout)   $3 = error message (stderr, strict)
missing_target() {
  local strict="$1" marker="$2" msg="$3"
  if [[ "$strict" == "1" ]]; then
    printf 'cerebro: error: %s\n' "$msg" >&2
    exit 3
  fi
  printf '%s\n' "$marker"
  exit 0
}

# True if $1 is among the remaining args.
contains() {
  local needle="$1"; shift
  local hay
  for hay in "$@"; do [[ "$hay" == "$needle" ]] && return 0; done
  return 1
}

# Resolve path $2 relative to repo $1, requiring the result to stay inside
# the repo. Echoes the absolute resolved path on stdout. Exits 6 if the path
# escapes. Uses python3 for cross-platform realpath (macOS lacks GNU realpath).
resolve_in_repo() {
  local repo="$1" rel="$2"
  python3 - "$repo" "$rel" <<'PY'
import os, sys
repo = os.path.realpath(sys.argv[1])
cand = sys.argv[2]
if not os.path.isabs(cand):
    cand = os.path.join(repo, cand)
cand = os.path.realpath(cand)
if cand != repo and not cand.startswith(repo + os.sep):
    sys.stderr.write(f"cerebro: error: path escapes repo: {sys.argv[2]}\n")
    sys.exit(6)
print(cand)
PY
}

# Validate that $1 is an absolute path to a git repo. Exits 3 on any failure.
require_git_repo() {
  local repo="$1"
  [[ "$repo" = /* ]] || err_path "repo path must be absolute: $repo"
  [[ -d "$repo" ]]   || err_path "repo not a directory: $repo"
  git --no-optional-locks -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || err_path "not a git repo: $repo"
}

# Canonicalize $1 to its git worktree root and echo it on stdout. Exits 3
# if $1 is not an absolute directory inside a git worktree. Bridges that
# read files from the user's repo (read/grep/ls) call this to anchor
# subsequent path resolution to the worktree boundary instead of trusting
# an arbitrary absolute directory.
canonical_worktree_root() {
  local repo="$1"
  [[ "$repo" = /* ]] || err_path "repo path must be absolute: $repo"
  [[ -d "$repo" ]]   || err_path "repo not a directory: $repo"
  local root
  root="$(git --no-optional-locks -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || err_path "not a git worktree: $repo"
  [[ -n "$root" ]] || err_path "not a git worktree: $repo"
  printf '%s\n' "$root"
}

# Echo the per-repo state key (sha1 of canonical worktree root, 16 hex).
# Returns non-zero (and prints nothing) when $1 is not a git worktree, so
# callers can treat a non-repo argument as "no key".
repo_state_key() {
  local canonical
  canonical="$(git --no-optional-locks -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$canonical" ]] || return 1
  python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])' "$canonical"
}

# Walk upward from an absolute path looking for an enclosing git worktree
# (a directory containing a `.git` file or directory). Echoes the worktree
# root on stdout if found; returns non-zero (and prints nothing) otherwise.
# Bounded to 12 levels so we don't traverse the entire filesystem.
find_enclosing_worktree() {
  local p="$1"
  [[ "$p" = /* ]] || return 1
  python3 - "$p" <<'PY' 2>/dev/null
import os, sys
p = os.path.realpath(sys.argv[1])
if os.path.isfile(p):
    p = os.path.dirname(p)
for _ in range(12):
    if os.path.exists(os.path.join(p, ".git")):
        print(p)
        sys.exit(0)
    parent = os.path.dirname(p)
    if parent == p:
        sys.exit(1)
    p = parent
sys.exit(1)
PY
}

# Resolve $1 (an absolute path) for a bare-abs read/grep/ls invocation.
# Echoes the realpathed result on stdout. Exit codes: 3 if not absolute
# (internal misuse only); 6 if it resolves under /dev /proc /sys (special
# filesystems / blocking devices) -- a security refusal callers MUST keep
# hard; 7 for a benign missing path or wrong type (no regular file or
# directory: FIFO, socket, char/block device) which callers may translate
# into a successful empty result. The in-repo escape guard in
# resolve_in_repo() does NOT apply -- this branch deliberately reads
# outside any repo.
resolve_bare_abs() {
  python3 - "$1" <<'PY'
import os, stat, sys
p = sys.argv[1]
if not os.path.isabs(p):
    sys.stderr.write(f"cerebro: error: path must be absolute: {p}\n")
    sys.exit(3)
try:
    r = os.path.realpath(p)
    st = os.stat(r)
except OSError as e:
    # Benign-eligible "missing" -- distinct sentinel so bridges can route
    # only this case through missing_target (security stays hard).
    sys.stderr.write(f"cerebro: error: cannot stat {p}: {e}\n")
    sys.exit(7)
for special in ("/dev/", "/proc/", "/sys/"):
    if r == special.rstrip("/") or r.startswith(special):
        sys.stderr.write(f"cerebro: error: refusing to read special path: {r}\n")
        sys.exit(6)
m = st.st_mode
if not (stat.S_ISREG(m) or stat.S_ISDIR(m)):
    # Benign-eligible "wrong type".
    sys.stderr.write(f"cerebro: error: not a regular file or directory: {r}\n")
    sys.exit(7)
print(r)
PY
}

# Map common short rg --type aliases to the canonical rg type name. Unknown
# inputs are passed through verbatim so rg emits its own diagnostic.
canonicalise_rg_type() {
  case "$1" in
    rs)  printf 'rust\n' ;;
    tsx) printf 'ts\n' ;;
    jsx) printf 'js\n' ;;
    yml) printf 'yaml\n' ;;
    rb)  printf 'ruby\n' ;;
    kt)  printf 'kotlin\n' ;;
    *)   printf '%s\n' "$1" ;;
  esac
}

usage() {
  cat <<'EOF'
usage:
  cerebro                       # start a new session (interactive chat)
  cerebro --resume [<id>]       # resume a session (id, or picker if omitted)
  cerebro list                  # list sessions, newest first
  cerebro --help                # this help

cerebro launches a native interactive `claude` chat configured as an
orchestrator. The orchestrator drives the plan -> execute -> review loop
by calling `cerebro <subcommand>` against your repositories on your
behalf. You stay in the chat -- you don't type the sub-commands yourself.

The orchestrator's tools are restricted to Read, Grep, Glob, and
`Bash(cerebro:*)`. Every git/gh/codex action and every file edit happens
inside a short-lived sub-agent that cerebro spawns; the orchestrator
itself can't touch repos directly.

Notes:
  * Interactive-only. cerebro refuses to run under a non-terminal parent
    (pipes, scripts, cron). Sub-agents launched by the orchestrator are
    exempt via $CEREBRO_SESSION_ID.
  * Concurrency. cerebro has no concurrency control: it will not stop
    you from running two mutating ops against the same repo at once,
    within or across sessions. Sequence your own mutating work.
  * No chat/PR/repo-specific flags are ever passed to `claude` or
    `codex`. The orchestrator addresses repos by absolute path as the
    first positional arg to its sub-agent tools.
  * Pair programming. Ask the orchestrator to "pair" (or watch / steer)
    a plan, execute, apply-review, or doc-write child and it adds
    `--pair`: the child runs with claude's stream-json input so you can
    WATCH it live from ANOTHER cerebro session -- ask that session to
    "observe <the paired session's id>" and it narrates, in plain English,
    what every live paired child is doing (and steers on your command) --
    and STEER it directly with `cerebro steer "<message>"` (a one-shot
    inject that returns at once; pass the pipe path from the PAIR MODE
    banner as a first arg when several run at once). The child runs to
    completion on its own; after each turn it waits a short window
    (CEREBRO_PAIR_IDLE, default 60s) for steering, and a quiet window
    finishes it. Each steering message is injected into the running
    session and recorded; when the child ends the orchestrator folds your
    steering into the session spec and the upcoming plans, then tells you
    what changed.

Requirements: claude, codex, jq, python3. Child claudes additionally
need git and gh on PATH for execute / apply-review / doc-write.

Env: CEREBRO_HOME, CEREBRO_MODEL, CEREBRO_REVIEW_MODEL, CEREBRO_TIMEOUT,
CEREBRO_CODEX_CMD, CEREBRO_CHILD_SESSION_TTL, CEREBRO_PAIR_IDLE,
CEREBRO_DEBUG.
EOF
}

# Interactive guard -- only runs for top-level invocations from a shell.
# Sub-agents spawned by the orchestrator have CEREBRO_SESSION_ID set and
# bypass this check; that's how `cerebro plan`, `cerebro execute`, ...
# can run inside the orchestrator's non-TTY Bash tool.
require_interactive() {
  [[ -n "${CEREBRO_SESSION_ID:-}" ]] && return 0
  if [[ ! -t 0 || ! -t 1 ]]; then
    die "cerebro is interactive-only; stdin and stdout must be terminals"
  fi
  local parent
  parent="$(ps -o comm= -p "$PPID" 2>/dev/null | awk '{print $1}')"
  parent="${parent##*/}"
  case "$parent" in
    -bash|bash|-zsh|zsh|-fish|fish|-sh|sh|-dash|dash|-ksh|ksh|-tcsh|tcsh) ;;
    tmux*|screen*|login|sshd) ;;
    *) die "cerebro is interactive-only; refused to run under parent '$parent'" ;;
  esac
}

require_deps() {
  local cmd
  for cmd in claude "$CEREBRO_CODEX_CMD" jq python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command on PATH: $cmd"
  done
}

require_session() {
  [[ -n "${CEREBRO_SESSION_ID:-}" ]] || {
    # Bare-resume fallback: hook writes a current-session symlink on
    # first user prompt, pointing at sessions/<id>/.
    if [[ -L "$CEREBRO_HOME/current-session" ]]; then
      local target
      target="$(readlink "$CEREBRO_HOME/current-session")"
      target="${target##*/}"
      [[ -n "$target" ]] && export CEREBRO_SESSION_ID="$target"
    fi
  }
  [[ -n "${CEREBRO_SESSION_ID:-}" ]] || die "no current cerebro session (CEREBRO_SESSION_ID unset and no current-session symlink). Did you launch this from a `cerebro` shell?"
  CEREBRO_SESSION_DIR="$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID"
  [[ -d "$CEREBRO_SESSION_DIR" ]] || die "session dir missing: $CEREBRO_SESSION_DIR"
  export CEREBRO_SESSION_DIR
}

mint_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

ts_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ts_compact() { date -u +%Y%m%dT%H%M%SZ; }

# Build a collision-resistant child-log path under the session's children/
# dir. We allow concurrent mutating runs (no per-repo lock), so two
# same-session invocations can start within the same second; a bare
# <subcmd>-<ts> name would let them share one file and produce truncated or
# interleaved logs. Keep the human-readable <subcmd>-<ts> prefix but append
# the PID plus a random token so each invocation gets a distinct file.
child_log_path() {
  local subcmd="$1"
  printf '%s\n' "$CEREBRO_SESSION_DIR/children/${subcmd}-$(ts_compact)-$$-${RANDOM}.jsonl"
}

# Append a structured event to the active session's transcript.
log_event() {
  local what="$1"; shift || true
  local extra="${1:-}"
  [[ -z "${CEREBRO_SESSION_DIR:-}" ]] && return 0
  local file="$CEREBRO_SESSION_DIR/transcript.jsonl"
  jq -nc --arg ts "$(ts_iso)" --arg what "$what" --arg extra "$extra" \
    '{kind:"event", ts:$ts, what:$what} + (if $extra == "" then {} else {detail:$extra} end)' \
    >> "$file" 2>/dev/null || true
}

# Timeout fallback chain (copied from bin/tai).
# CEREBRO_TIMEOUT unset/empty/0/none/unlimited => no cap: run the child
# directly (TIMEOUT_CMD=(env)), so the perl alarm path can never fire.
# Only a positive integer arms timeout/gtimeout/perl.
build_timeout_cmd() {
  case "${CEREBRO_TIMEOUT:-0}" in
    ''|0|none|unlimited|NONE|UNLIMITED)
      TIMEOUT_CMD=(env)
      return 0
      ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout "$CEREBRO_TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(gtimeout "$CEREBRO_TIMEOUT")
  elif command -v perl >/dev/null 2>&1; then
    TIMEOUT_CMD=(perl -e 'alarm shift; exec @ARGV' "$CEREBRO_TIMEOUT")
  else
    TIMEOUT_CMD=(env)
  fi
}

# Write the embedded payloads (hook.sh, system-prompt.md, settings.local.json)
# into $CEREBRO_HOME. Idempotent: existing files are overwritten only if their
# content differs, so subsequent runs see an up-to-date copy without churn.
materialise_home() {
  mkdir -p "$CEREBRO_HOME/.claude" "$CEREBRO_HOME/sessions" \
    "$CEREBRO_HOME/templates" \
    || die "cannot create $CEREBRO_HOME"

  write_if_changed "$CEREBRO_HOME/system-prompt.md" "$(cerebro_system_prompt)"
  write_if_changed "$CEREBRO_HOME/hook.sh" "$(cerebro_hook_script)"
  chmod +x "$CEREBRO_HOME/hook.sh"

  local settings; settings="$(cerebro_settings_json "$CEREBRO_HOME/hook.sh")"
  write_if_changed "$CEREBRO_HOME/.claude/settings.local.json" "$settings"

  # Templates are user-editable defaults: write only when the file is
  # missing so a user who customizes ~/.cerebro/templates/AGENTS.md
  # isn't clobbered on the next launch.
  write_if_missing "$CEREBRO_HOME/templates/AGENTS.md" "$(cerebro_default_agents_md)"
  write_if_missing "$CEREBRO_HOME/templates/CLAUDE.md" "$(cerebro_default_claude_md)"
}

write_if_changed() {
  local path="$1" content="$2"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
    return 0
  fi
  printf '%s' "$content" > "$path"
}

write_if_missing() {
  local path="$1" content="$2"
  [[ -f "$path" ]] && return 0
  printf '%s' "$content" > "$path"
}

