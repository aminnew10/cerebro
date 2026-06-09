# cerebro lib: commands/gh
# read-only gh bridge
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro gh <repo> <subcmd> [args...] --------------------

# Accept-list dispatcher for a gh top-level command. Compares $sub against
# the list of allow-listed verbs ($3..$N) and err_subcmds when no match.
_gh_accept_verb() {
  local top="$1" sub="$2"; shift 2
  local v
  for v in "$@"; do
    [[ "$sub" == "$v" ]] && return 0
  done
  err_subcmd "gh $top: '$sub' not allow-listed (allowed: $*)"
}

# Validate argv following `gh codespace ports`. The bare form lists forwarded
# ports (read), but `ports forward <port>` and `ports visibility <port>:vis`
# are mutating subcommands. A flat scan would false-positive on legitimate
# reads like `ports --json visibility` (a JSON field) or `-c visibility`
# (a codespace named `visibility`). Walk argv flag-aware: skip the value of
# known value-taking flags, treat `--flag=value` as self-contained, then
# inspect only the first non-flag positional -- the actual subcommand slot.
_gh_codespace_ports_validate() {
  # Maintenance burden: gh evolves; if a new value-consuming flag is added to
  # gh codespace, add it here to avoid false-negatives on the forward/visibility
  # subcommand check. The list covers flags from any gh codespace subcommand
  # (not just `ports`) so leaked-through usage still parses correctly.
  local tok consume=0
  while (( $# )); do
    tok="$1"; shift
    if (( consume )); then
      consume=0
      continue
    fi
    case "$tok" in
      --*=*) ;;  # equals-form flag carries its own value
      --codespace|--repo|--repo-owner|--branch|--json|--jq|--template|\
      --display-name|--idle-timeout|--retention-period|--machine|--location|\
      --devcontainer-path)
        consume=1 ;;
      -c|-R|-B|-t|-q)
        consume=1 ;;
      -*) ;;     # other flags: bool/unknown -- do not consume next
      forward|visibility)
        err_subcmd "gh codespace ports: '$tok' not allowed (only bare list form)" ;;
      *) return 0 ;;  # other positional first -- not a mutating verb
    esac
  done
  return 0
}

cmd_gh() {
  require_session
  local repo="${1:-}"; shift || true
  local top="${1:-}"; shift || true
  [[ -n "$repo" && -n "$top" ]] \
    || err_usage "usage: cerebro gh <repo-abs-path> <subcmd> [args...]"
  require_git_repo "$repo"

  local sub="${1:-}"  # may be empty for `gh status` / `gh completion`
  case "$top" in
    pr)         _gh_accept_verb "pr"          "$sub" view list diff checks status ;;
    issue)      _gh_accept_verb "issue"       "$sub" view list status ;;
    run)        _gh_accept_verb "run"         "$sub" view list watch ;;
    repo)       _gh_accept_verb "repo"        "$sub" view list ;;
    release)    _gh_accept_verb "release"     "$sub" view list verify ;;
    search)     _gh_accept_verb "search"      "$sub" repos prs issues code commits ;;
    auth)       _gh_accept_verb "auth"        "$sub" status ;;
    workflow)   _gh_accept_verb "workflow"    "$sub" view list ;;
    ruleset)    _gh_accept_verb "ruleset"     "$sub" view list check ;;
    project)    _gh_accept_verb "project"     "$sub" view list field-list item-list ;;
    secret)     _gh_accept_verb "secret"      "$sub" list ;;
    variable)   _gh_accept_verb "variable"    "$sub" list get ;;
    cache)      _gh_accept_verb "cache"       "$sub" list ;;
    label)      _gh_accept_verb "label"       "$sub" list ;;
    ssh-key)    _gh_accept_verb "ssh-key"     "$sub" list ;;
    gpg-key)    _gh_accept_verb "gpg-key"     "$sub" list ;;
    codespace)
      _gh_accept_verb "codespace"   "$sub" view list logs ports
      # `gh codespace ports` (bare) lists forwarded ports;
      # `gh codespace ports forward <port>` and `... visibility <spec>`
      # mutate, and `gh` parses them as subcommands even when flags
      # precede them (`ports -c <name> forward 8080:8080`). Walk the
      # post-`ports` argv flag-aware so values like `--json visibility`
      # or `-c visibility` don't trip a flat token scan.
      [[ "$sub" == "ports" ]] && _gh_codespace_ports_validate "${@:2}"
      ;;
    attestation) _gh_accept_verb "attestation" "$sub" verify ;;
    org)        _gh_accept_verb "org"         "$sub" list ;;
    alias)      _gh_accept_verb "alias"       "$sub" list ;;
    config)     _gh_accept_verb "config"      "$sub" get list ;;
    gist)       _gh_accept_verb "gist"        "$sub" view list ;;
    licenses)   _gh_accept_verb "licenses"    "$sub" list view ;;
    extension)
      case "$sub" in
        list|search) ;;
        install)
          err_subcmd "gh extension: 'install' runs arbitrary code; not allow-listed" ;;
        *) err_subcmd "gh extension: '$sub' not allow-listed (allowed: list search)" ;;
      esac ;;
    status|completion)
      # Bare tops; no verb gating. Args still flow through.
      ;;
    api)
      # api accepts any GET; reject mechanisms that change the method or
      # add a request body. The `-X*`/`-F*`/`-f*` globs catch attached
      # short forms like `-XPOST`, `-Ffoo=bar`, `-ffoo=bar` -- gh accepts
      # those just as eagerly as the spaced form.
      local a
      for a in "$@"; do
        case "$a" in
          -X*|-F*|-f*\
          |--method|--method=*\
          |--field|--field=*\
          |--raw-field|--raw-field=*\
          |--input|--input=*)
            err_flag "gh api: write flag: $a" ;;
        esac
      done ;;
    browse|copilot|preview|agent-task|co|skill)
      err_subcmd "gh: top-level command not allow-listed: $top (side-effect: browser/interactive/install)" ;;
    *)
      err_subcmd "gh: top-level command not allow-listed: $top" ;;
  esac

  log_event "gh" "$repo $top $*"
  cd "$repo" || err_path "gh: cannot cd to $repo"
  exec gh "$top" "$@"
}

