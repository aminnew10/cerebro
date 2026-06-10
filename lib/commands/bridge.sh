# cerebro lib: commands/bridge
# read-only exploration bridges: ls / read / grep
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- subcommand: cerebro ls <repo> [path] --------------------------------

cmd_ls() {
  require_session
  local strict=0 repo="" path="" got=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict-missing) strict=1 ;;
      --*) err_usage "ls: unknown arg: $1; canonical: cerebro ls <repo-abs-path> [path] | cerebro ls <abs-dir> [--strict-missing]" ;;
      *)
        if [[ $got -eq 0 ]]; then repo="$1"; got=1
        elif [[ $got -eq 1 ]]; then path="$1"; got=2
        else err_usage "ls: too many positionals: $1; canonical: cerebro ls <repo-abs-path> [path]"
        fi ;;
    esac
    shift
  done
  [[ -n "$repo" ]] || err_usage "usage: cerebro ls <repo-abs-path> [path] | cerebro ls <abs-dir>"

  local target rc
  if root="$(canonical_worktree_root "$repo" 2>/dev/null)"; then
    repo="$root"
    target="$repo"
    if [[ -n "$path" ]]; then
      target="$(resolve_in_repo "$repo" "$path")" || exit $?
    fi
  elif [[ "$repo" = /* && -z "$path" ]]; then
    target="$(resolve_bare_abs "$repo")" || { rc=$?; [[ $rc -eq 7 ]] && missing_target "$strict" "(not found: $repo)" "ls: not found: $repo"; exit $rc; }
  elif [[ "$repo" != /* ]]; then
    # Relative repo arg is a shape error, not a missing target.
    err_usage "ls: repo path must be absolute: $repo; canonical: cerebro ls <repo-abs-path> [path] | cerebro ls <abs-dir>"
  else
    # Absolute path that isn't a worktree: benign "nothing here".
    missing_target "$strict" "(not found: $repo)" "ls: repo not a git worktree: $repo"
  fi
  [[ -d "$target" ]] || missing_target "$strict" "(not found: ${path:-$repo})" "ls: not a directory: ${path:-$repo}"

  log_event "ls" "$target"
  python3 "$CEREBRO_LIB_DIR/python/list_dir.py" "$target"
}

# ----- subcommand: cerebro read <repo> <path> [--range N:M] ----------------

cmd_read() {
  require_session
  local arg1="${1:-}"; shift || true
  local arg2=""
  # The second positional is a path only if it isn't a flag. This lets us
  # spot the "abs-path tumbled into the file slot" shape: when the legacy
  # `<repo> <path>` form would put a flag where the path belongs, the
  # caller really meant `cerebro read <abs-path> [--flags]`.
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    arg2="$1"; shift
  fi
  local range="" from="" to="" strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict-missing) strict=1; shift ;;
      --range)
        shift
        local rv="${1:-}"
        [[ -n "$rv" ]] || err_usage "read: --range requires a value; canonical: --range N:M | N M | N-M | N..M | N | :M"
        shift || true
        local r_lo r_hi
        case "$rv" in
          *:*)
            r_lo="${rv%%:*}"; r_hi="${rv#*:}" ;;
          *..*)
            r_lo="${rv%%..*}"; r_hi="${rv##*..}" ;;
          *-*)
            # N-M only when both sides are pure digits; leave refs like
            # HEAD-1 alone.
            local r_left="${rv%%-*}" r_right="${rv#*-}"
            if [[ "$r_left" =~ ^[0-9]+$ && "$r_right" =~ ^[0-9]+$ ]]; then
              r_lo="$r_left"; r_hi="$r_right"
            else
              err_usage "read: bad --range value: $rv; canonical: --range N:M | N-M | N..M | N M"
            fi ;;
          *)
            if [[ "$rv" =~ ^[0-9]+$ ]]; then
              r_lo="$rv"; r_hi=""
              # Peek next argv: if it's pure-digits, consume it as M.
              if [[ $# -gt 0 && "${1:-}" =~ ^[0-9]+$ ]]; then
                r_hi="$1"
                shift || true
              fi
            elif [[ "$rv" == :* && "${rv#:}" =~ ^[0-9]*$ ]]; then
              r_lo=""; r_hi="${rv#:}"
            else
              err_usage "read: bad --range value: $rv; canonical: --range N:M | N-M | N..M | N M"
            fi ;;
        esac
        if [[ -n "$r_lo" && ! "$r_lo" =~ ^[0-9]+$ ]]; then
          err_usage "read: bad --range lower bound: $r_lo; canonical: --range N:M"
        fi
        if [[ -n "$r_hi" && ! "$r_hi" =~ ^[0-9]+$ ]]; then
          err_usage "read: bad --range upper bound: $r_hi; canonical: --range N:M"
        fi
        range="$r_lo:$r_hi" ;;
      --from)
        shift
        local fv="${1:-}"
        [[ -n "$fv" ]] || err_usage "read: --from requires a value; canonical: --from N --to M"
        shift || true
        from="$fv" ;;
      --to)
        shift
        local tv="${1:-}"
        [[ -n "$tv" ]] || err_usage "read: --to requires a value; canonical: --from N --to M"
        shift || true
        to="$tv" ;;
      *) err_usage "read: unknown arg: $1; canonical: cerebro read <repo> <path> [--range N:M] | cerebro read <abs-path> [--range N:M]" ;;
    esac
  done

  if [[ -n "$from$to" ]]; then
    [[ -z "$range" ]] || err_usage "read: --from/--to is mutually exclusive with --range"
    [[ -n "$from" && -n "$to" ]] || err_usage "read: --from and --to must be paired; canonical: --from N --to M"
    [[ "$from" =~ ^[0-9]+$ ]] || err_usage "read: bad --from value: $from"
    [[ "$to"   =~ ^[0-9]+$ ]] || err_usage "read: bad --to value: $to"
    range="$from:$to"
  fi

  [[ -n "$arg1" ]] || err_usage "usage: cerebro read <repo-abs-path> <path> [--range N:M] | cerebro read <abs-path> [--range N:M]"

  local repo="" path="" resolved="" rc
  if [[ -n "$arg2" ]]; then
    # Two positionals supplied. Try the legacy `<repo> <path>` form first.
    if root="$(canonical_worktree_root "$arg1" 2>/dev/null)"; then
      repo="$root"
      path="$arg2"
      resolved="$(resolve_in_repo "$repo" "$path")" || exit $?
    elif [[ "$arg1" = /* && -f "$arg1" ]]; then
      # arg1 is an abs file path with a stray second positional -- treat
      # arg1 as the file and try to infer the enclosing repo.
      path="$arg1"
      if repo="$(find_enclosing_worktree "$arg1")" && [[ -n "$repo" ]]; then
        warn "read: inferred repo=$repo from abs path"
        resolved="$(resolve_in_repo "$repo" "$path")" || exit $?
      else
        # Fall through to bare-abs reading the file itself.
        resolved="$(resolve_bare_abs "$arg1")" || { rc=$?; [[ $rc -eq 7 ]] && missing_target "$strict" "(not found: ${path:-$arg1})" "read: not found: ${path:-$arg1}"; exit $rc; }
      fi
    elif [[ "$arg1" != /* ]]; then
      # Relative repo arg is a shape error, not a missing target.
      err_usage "read: repo path must be absolute: $arg1; canonical: cerebro read <repo-abs-path> <path> | cerebro read <abs-path>"
    else
      # Absolute path that isn't a worktree: benign "nothing here".
      missing_target "$strict" "(not found: $arg1)" "read: repo not a git worktree: $arg1"
    fi
  else
    # Single positional. If it's absolute and a regular file, try repo
    # inference (A1), then fall back to bare-abs (D1).
    if [[ "$arg1" = /* ]]; then
      if [[ -f "$arg1" ]]; then
        if repo="$(find_enclosing_worktree "$arg1")" && [[ -n "$repo" ]]; then
          path="$arg1"
          warn "read: inferred repo=$repo from abs path"
          resolved="$(resolve_in_repo "$repo" "$path")" || exit $?
        else
          resolved="$(resolve_bare_abs "$arg1")" || { rc=$?; [[ $rc -eq 7 ]] && missing_target "$strict" "(not found: ${path:-$arg1})" "read: not found: ${path:-$arg1}"; exit $rc; }
        fi
      else
        resolved="$(resolve_bare_abs "$arg1")" || { rc=$?; [[ $rc -eq 7 ]] && missing_target "$strict" "(not found: ${path:-$arg1})" "read: not found: ${path:-$arg1}"; exit $rc; }
      fi
    else
      err_usage "usage: cerebro read <repo-abs-path> <path> [--range N:M] | cerebro read <abs-path> [--range N:M]"
    fi
  fi

  [[ -f "$resolved" ]] || missing_target "$strict" "(not found: ${path:-$arg1})" "read: not a regular file: ${path:-$arg1}"

  log_event "read" "$resolved"

  if [[ -z "$range" ]]; then
    cat -- "$resolved"
    return
  fi
  python3 "$CEREBRO_LIB_DIR/python/read_range.py" "$resolved" "$range"
}

# ----- subcommand: cerebro grep <repo> <pattern> [opts] --------------------

cmd_grep() {
  require_session
  local repo="${1:-}"; shift || true
  local pattern="${1:-}"; shift || true
  [[ -n "$repo" && -n "$pattern" ]] \
    || err_usage "usage: cerebro grep <repo-abs-path> <pattern> [--glob G]... [--type T]... [--fixed-strings] [-i] [--path SUB]; canonical: cerebro grep <repo> <pattern> | cerebro grep <abs-dir> <pattern>"
  command -v rg >/dev/null 2>&1 || die "grep: ripgrep (rg) not installed"

  local rg_args=() sub="" strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict-missing)   strict=1 ;;
      --glob)             shift; rg_args+=(--glob "${1:-}") ;;
      --type)
        shift
        local raw_type="${1:-}"
        local ct
        ct="$(canonicalise_rg_type "$raw_type")"
        rg_args+=(--type "$ct") ;;
      --fixed-strings|-F) rg_args+=(--fixed-strings) ;;
      -i|--ignore-case)   rg_args+=(--ignore-case) ;;
      --path)             shift; sub="${1:-}" ;;
      *) err_usage "grep: unknown arg: $1; canonical: cerebro grep <repo> <pattern> [--glob G] [--type T] [--fixed-strings] [-i] [--path SUB]" ;;
    esac
    shift || true
  done

  local target="" rc
  if root="$(canonical_worktree_root "$repo" 2>/dev/null)"; then
    target="$root"
    repo="$root"
    if [[ -n "$sub" ]]; then
      target="$(resolve_in_repo "$repo" "$sub")" || exit $?
    fi
  elif [[ "$repo" = /* ]]; then
    target="$(resolve_bare_abs "$repo")" || { rc=$?; [[ $rc -eq 7 ]] && missing_target "$strict" "(not found: $repo)" "grep: not found: $repo"; exit $rc; }
    if [[ -n "$sub" ]]; then
      target="$(resolve_bare_abs "$target/$sub")" || { rc=$?; [[ $rc -eq 7 ]] && missing_target "$strict" "(not found: ${sub:-$repo})" "grep: not found: $sub"; exit $rc; }
    fi
  else
    # Relative repo arg is a shape error, not a missing target.
    err_usage "grep: repo path must be absolute: $repo; canonical: cerebro grep <repo-abs-path> <pattern> | cerebro grep <abs-dir> <pattern>"
  fi

  # An in-repo --path sub is resolved without stat'ing, so a missing one
  # would reach rg as exit 2; treat the benign miss here instead.
  [[ -e "$target" ]] || missing_target "$strict" "(not found: ${sub:-$repo})" "grep: not found: ${sub:-$repo}"

  log_event "grep" "$target $pattern"
  # `${arr[@]+"${arr[@]}"}` is the bash-3.2-safe form: on macOS's bash,
  # expanding an empty `${arr[@]}` under `set -u` is treated as unbound
  # and aborts. The +alt expansion produces nothing when the array is
  # empty and the normal quoted expansion otherwise.
  rg --no-heading --line-number --color never \
     --max-count 200 --max-columns 400 \
     ${rg_args[@]+"${rg_args[@]}"} -- "$pattern" "$target"
  rc=$?
  if [[ "$strict" == "1" ]]; then
    exit "$rc"                      # native rg semantics: 1 = no matches
  fi
  case "$rc" in
    0) exit 0 ;;                    # matches found
    1) printf '(no matches)\n'; exit 0 ;;   # benign zero-match
    *) exit "$rc" ;;                # >=2: genuine rg error (bad regex, etc.) stays hard
  esac
}

