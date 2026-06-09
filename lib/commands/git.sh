# cerebro lib: commands/git
# read-only git bridge
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro git <repo> <subcmd> [args...] -------------------

# Read-only git subcommands the orchestrator may invoke. Some allow both
# read and write modes; per-subcommand validators enforce the read mode.
# Pure-read entries have no validator; mixed-mode entries (archive, fsck,
# hash-object, interpret-trailers, apply, bundle, notes, submodule,
# worktree, replace, bisect, symbolic-ref, mailinfo, fast-export, fetch,
# branch, tag, config, stash, remote, reflog, diff, show, log, blame,
# ls-files) are gated by validate_git_subcmd_args().
readonly CEREBRO_GIT_ALLOWED=(
  status log diff show blame ls-files ls-tree branch remote
  rev-parse cat-file describe tag config for-each-ref
  stash reflog shortlog name-rev merge-base
  rev-list ls-remote fetch count-objects show-ref show-branch
  verify-commit verify-tag whatchanged range-diff
  diff-tree diff-index diff-files grep
  check-ignore check-attr check-ref-format var help version
  patch-id request-pull merge-tree get-tar-commit-id fast-export
  archive fsck hash-object interpret-trailers apply
  bundle notes submodule worktree replace bisect column columns
  symbolic-ref mailinfo
)

# Flags that can write or escape the repo when passed to git. Matched in
# both bare and "=value" forms. Most of these are top-level git options that
# only work BEFORE the subcommand, which our argv shape (git -C repo sub
# args...) already prevents; this is defense in depth.
readonly CEREBRO_GIT_DENY_GLOBAL=(
  --exec --upload-pack --receive-pack --git-dir --work-tree --namespace
  -c -C --bare --no-pager --paginate --no-replace-objects --literal-pathspecs
  --exec-path --html-path --man-path --info-path
  --output --output-directory
)

is_denied_global_git_flag() {
  local a="$1" bad
  for bad in "${CEREBRO_GIT_DENY_GLOBAL[@]}"; do
    [[ "$a" == "$bad" || "$a" == "$bad"=* ]] && return 0
  done
  return 1
}

# Flags that explicitly opt into running external helper programs (diff
# drivers, textconv programs, smudge/clean filters). Rejected on any git
# subcommand as defense in depth -- diff/log/show already get `--no-ext-diff
# --no-textconv` injected at invocation time, but allowing `--ext-diff` /
# `--textconv` / `--filters` on the argv could re-enable a helper. The OFF
# forms (`--no-ext-diff`, `--no-textconv`) stay allowed.
is_helper_git_flag() {
  local a="$1"
  case "$a" in
    --ext-diff|--ext-diff=*|--textconv|--textconv=*|--filters|--filters=*)
      return 0 ;;
  esac
  return 1
}

# Overrides injected via `git -c key=value` right after `git`. `core.fsmonitor=`
# (empty value) disables the fsmonitor hook; `core.hooksPath=/dev/null` points
# the hooks dir at a non-directory so no hooks load. We do NOT inject
# `-c diff.external=` -- an empty value makes git try to exec the empty
# string and fail every diff -- use `--no-ext-diff` per-subcommand instead.
# Likewise `-c diff.textconv=` and `-c filter.*.smudge=` don't behave like
# wildcards in git's `-c` parser, so we rely on `--no-textconv` per-subcommand
# and on rejecting `--filters` to keep smudge/clean from firing.
readonly CEREBRO_GIT_OVERRIDES=(
  -c core.fsmonitor=
  -c core.hooksPath=/dev/null
)

# Per-subcommand validator. Args: subcmd, remaining-argv.
validate_git_subcmd_args() {
  local sub="$1"; shift
  local a saw_list=0 ok=0
  case "$sub" in
    branch)
      for a in "$@"; do
        case "$a" in
          -d|-D|--delete|-m|-M|--move|--copy|--copy=*|-f|--force\
          |--set-upstream-to|--set-upstream-to=*|--unset-upstream\
          |--edit-description|--create-reflog|--track|--track=*|--no-track)
            err_flag "git branch: mutating flag: $a" ;;
          -*) ;;
          *) err_flag "git branch: positional arg implies create/rename; deny: $a" ;;
        esac
      done ;;
    tag)
      for a in "$@"; do
        case "$a" in
          --list|-l) saw_list=1 ;;
          -d|-D|--delete|-m|-a|-s|--sign|-f|--force|--create-reflog|--cleanup=*)
            err_flag "git tag: mutating flag: $a" ;;
          -*) ;;
          *)
            (( saw_list )) || err_flag "git tag: positional arg without --list: $a" ;;
        esac
      done ;;
    config)
      for a in "$@"; do
        case "$a" in
          --get|--get-all|--get-regexp|--get-urlmatch|-l|--list|--show-origin|--show-scope)
            ok=1 ;;
          --add|--unset|--unset-all|--replace-all|--edit|-e\
          |--rename-section|--remove-section)
            err_flag "git config: write flag: $a" ;;
          --file|--file=*|-f|-f*\
          |--global|--system|--worktree|--blob|--blob=*)
            err_flag "git config: scope/path flag bypasses repo boundary: $a" ;;
        esac
      done
      (( ok )) || err_flag "git config: missing --get/--list" ;;
    stash)
      case "${1:-list}" in
        list|show) ;;
        *) err_flag "git stash: only list/show allowed (got ${1:-})" ;;
      esac ;;
    remote)
      # Accept an optional verbosity flag before the action, then require
      # the action itself to be empty/show/get-url. Without this split,
      # `git remote -v add foo url` would slip past as a "verbose" form.
      local action="${1:-}"
      if [[ "$action" == "-v" || "$action" == "--verbose" ]]; then
        action="${2:-}"
      fi
      case "$action" in
        ''|show|get-url) ;;
        add|set-url|remove|rm|rename|prune|update|set-head|set-branches)
          err_flag "git remote: mutating action: $action" ;;
        *) err_flag "git remote: only -v/show/get-url allowed (got $action)" ;;
      esac ;;
    reflog)
      case "${1:-show}" in
        show) ;;
        *) err_flag "git reflog: only show allowed (got ${1:-})" ;;
      esac ;;
    diff)
      for a in "$@"; do
        case "$a" in
          --no-index|--no-index=*)
            err_flag "git diff: --no-index reads arbitrary paths: $a" ;;
          --orderfile|--orderfile=*|-O|-O=*)
            err_flag "git diff: --orderfile reads external file: $a" ;;
        esac
      done ;;
    blame)
      for a in "$@"; do
        case "$a" in
          --contents|--contents=*)
            err_flag "git blame: --contents reads arbitrary file: $a" ;;
          --ignore-revs-file|--ignore-revs-file=*)
            err_flag "git blame: --ignore-revs-file reads external file: $a" ;;
        esac
      done ;;
    show)
      for a in "$@"; do
        case "$a" in
          --orderfile|--orderfile=*|-O|-O=*)
            err_flag "git show: --orderfile reads external file: $a" ;;
        esac
      done ;;
    log)
      for a in "$@"; do
        case "$a" in
          --orderfile|--orderfile=*|-O|-O=*)
            err_flag "git log: --orderfile reads external file: $a" ;;
        esac
      done ;;
    ls-files)
      for a in "$@"; do
        case "$a" in
          -X|--exclude-from|--exclude-from=*\
          |--exclude-per-directory|--exclude-per-directory=*)
            err_flag "git ls-files: external-file flag: $a" ;;
        esac
      done ;;
    archive)
      for a in "$@"; do
        case "$a" in
          -o|-o=*|--output|--output=*)
            err_flag "git archive: --output writes a file; use stdout: $a" ;;
        esac
      done ;;
    fsck)
      for a in "$@"; do
        case "$a" in
          --write-cache|--write-cache=*)
            err_flag "git fsck: --write-cache mutates: $a" ;;
          --lost-found|--lost-found=*)
            err_flag "git fsck: --lost-found writes files: $a" ;;
        esac
      done ;;
    hash-object)
      for a in "$@"; do
        case "$a" in
          -w|--stdin-paths)
            err_flag "git hash-object: -w writes to .git/objects: $a" ;;
        esac
      done ;;
    interpret-trailers)
      for a in "$@"; do
        case "$a" in
          --in-place|--in-place=*)
            err_flag "git interpret-trailers: --in-place writes: $a" ;;
        esac
      done ;;
    apply)
      local has_check=0
      for a in "$@"; do [[ "$a" == "--check" ]] && has_check=1; done
      (( has_check )) || err_flag "git apply: only --check form allowed (would apply otherwise)" ;;
    bundle)
      case "${1:-}" in
        verify|list-heads) ;;
        *) err_flag "git bundle: only verify/list-heads allowed (got ${1:-})" ;;
      esac ;;
    notes)
      case "${1:-list}" in
        list|show) ;;
        *) err_flag "git notes: only list/show allowed (got ${1:-})" ;;
      esac ;;
    submodule)
      case "${1:-}" in
        status|summary) ;;
        *) err_flag "git submodule: only status/summary allowed (got ${1:-})" ;;
      esac ;;
    worktree)
      case "${1:-}" in
        list) ;;
        *) err_flag "git worktree: only list allowed (got ${1:-})" ;;
      esac ;;
    replace)
      # `git replace` with no args lists replacements; `--list`/`-l` also
      # lists (optionally filtered by a pattern positional). Any other
      # positional is the SET form `git replace <object> <replacement>`,
      # which writes a replacement ref.
      saw_list=0
      for a in "$@"; do
        case "$a" in
          --list|-l) saw_list=1 ;;
          --add|--edit|--delete|-d|--graft|--graft=*|--convert-graft-file)
            err_flag "git replace: mutating flag: $a" ;;
        esac
      done
      for a in "$@"; do
        case "$a" in
          -*) ;;
          *)
            (( saw_list )) || err_flag "git replace: positional arg without --list: $a" ;;
        esac
      done ;;
    bisect)
      case "${1:-}" in
        view|log) ;;
        *) err_flag "git bisect: only view/log allowed (got ${1:-})" ;;
      esac ;;
    symbolic-ref)
      # `git symbolic-ref <name>` reads; `git symbolic-ref <name> <ref>`
      # writes. `-d`/`--delete` is also a write but uses only one positional,
      # so the positional-count guard alone misses it; deny it explicitly.
      local positional=0
      for a in "$@"; do
        case "$a" in
          -d|--delete)
            err_flag "git symbolic-ref: mutating flag: $a" ;;
          -*) ;;
          *) positional=$((positional + 1)) ;;
        esac
      done
      (( positional <= 1 )) || err_flag "git symbolic-ref: SET form (two positionals) is a write" ;;
    mailinfo)
      for a in "$@"; do
        case "$a" in
          -*) ;;
          *) err_flag "git mailinfo: positional args name output files; refuse" ;;
        esac
      done ;;
    fast-export)
      # `git fast-export` writes its stream to stdout (fine), but
      # `--export-marks=<file>` and `--import-marks*=<file>` open arbitrary
      # external paths for write/read outside the repo.
      for a in "$@"; do
        case "$a" in
          --export-marks|--export-marks=*\
          |--import-marks|--import-marks=*\
          |--import-marks-if-exists|--import-marks-if-exists=*)
            err_flag "git fast-export: mutating flag: $a" ;;
        esac
      done ;;
    fetch)
      # Bare `git fetch [<remote>]` is allowed. The flags below mutate more
      # than the default fetch (prune refs, force overwrite local refs,
      # change shallowness, write submodule config) -- reject them. Note
      # that `--no-write-fetch-head` / `--write-fetch-head=false` are not
      # denied: they only suppress writing FETCH_HEAD, which is a
      # narrowing, not a widening.
      for a in "$@"; do
        case "$a" in
          --prune|-p|--prune-tags\
          |--force|-f\
          |--update-head-ok\
          |--multiple\
          |--shallow-since|--shallow-since=*\
          |--shallow-exclude|--shallow-exclude=*\
          |--deepen|--deepen=*\
          |--unshallow\
          |--recurse-submodules-default|--recurse-submodules-default=*)
            err_flag "git fetch: mutating flag: $a" ;;
        esac
      done ;;
  esac
}

cmd_git() {
  require_session
  local repo="${1:-}"; shift || true
  local sub="${1:-}"; shift || true
  [[ -n "$repo" && -n "$sub" ]] \
    || err_usage "usage: cerebro git <repo-abs-path> <subcmd> [args...]"
  require_git_repo "$repo"

  # The subcommand position must hold a subcommand name, not a flag --
  # otherwise an arg like `-c foo=bar` would slip past as `git -c foo=bar
  # <real-subcmd>`, which sets arbitrary git config.
  case "$sub" in
    -*) err_flag "git: subcommand position cannot be a flag: $sub" ;;
  esac
  contains "$sub" "${CEREBRO_GIT_ALLOWED[@]}" \
    || err_subcmd "git: subcommand not on allow-list: $sub"

  local a
  for a in "$@"; do
    is_denied_global_git_flag "$a" && err_flag "git: denied global flag: $a"
    is_helper_git_flag "$a" && err_flag "git: external helper flag: $a"
  done

  validate_git_subcmd_args "$sub" "$@"

  log_event "git" "$repo $sub $*"
  # `--no-optional-locks` keeps reads from touching .git/index. For `config`,
  # inject `--local` so reads are pinned to the repo and can't pick up
  # $HOME/.gitconfig or /etc/gitconfig (validate_git_subcmd_args has already
  # rejected user-supplied scope/path flags). GIT_CONFIG_NOSYSTEM=1 skips
  # /etc/gitconfig too. The `-c` overrides blank fsmonitor and hooks; for
  # diff/log/show we additionally inject `--no-ext-diff --no-textconv` so a
  # repo's `.git/config` cannot slip an external helper past the bridge.
  export GIT_CONFIG_NOSYSTEM=1
  if [[ "$sub" == "config" ]]; then
    exec git "${CEREBRO_GIT_OVERRIDES[@]}" \
      --no-optional-locks -C "$repo" config --local "$@"
  fi
  case "$sub" in
    diff|log|show|whatchanged|diff-tree|diff-index|diff-files|grep|range-diff)
      exec git "${CEREBRO_GIT_OVERRIDES[@]}" \
        --no-optional-locks -C "$repo" \
        "$sub" --no-ext-diff --no-textconv "$@" ;;
    fsck)
      exec git "${CEREBRO_GIT_OVERRIDES[@]}" \
        --no-optional-locks -C "$repo" \
        fsck --no-progress "$@" ;;
  esac
  exec git "${CEREBRO_GIT_OVERRIDES[@]}" \
    --no-optional-locks -C "$repo" "$sub" "$@"
}

