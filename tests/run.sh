#!/usr/bin/env bash
# Plain-bash tests for cerebro's read-only bridge subcommands. No external
# test framework. Run with: bash tests/run.sh
#
# We exercise validation paths -- denied subcommands, denied flags, path
# containment -- which fire before any actual git/gh/rg invocation. The
# happy-path tests do invoke real git and rg.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEREBRO_BIN="$here/../bin/cerebro"
[[ -x "$CEREBRO_BIN" ]] || { echo "cerebro not found or not executable: $CEREBRO_BIN" >&2; exit 1; }

# Isolated sandbox.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export CEREBRO_HOME="$WORKDIR/cerebro-home"
export CEREBRO_SESSION_ID="test-session"
mkdir -p "$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID/plans" \
         "$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID/children"
: > "$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID/transcript.jsonl"

REPO="$WORKDIR/repo"
mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q -b main . 2>/dev/null || git init -q .
  git config user.email test@example.com
  git config user.name test
  git commit --allow-empty -q -m init
  : > a.txt
  git add a.txt
  git commit -q -m "add a.txt"
) || { echo "failed to set up test repo" >&2; exit 1; }

pass=0
fail=0
failures=()

# run_case <id> <description> <expected-rc> -- <cmd...>
# Optional: STDERR_CONTAINS=<substring> env to assert a substring of stderr.
# Optional: STDOUT_CONTAINS=<substring> env to assert a substring of stdout.
run_case() {
  local id="$1" desc="$2" expected="$3"
  shift 3
  [[ "$1" == "--" ]] && shift
  local needle="${STDERR_CONTAINS:-}"
  local out_needle="${STDOUT_CONTAINS:-}"
  local out err rc
  out="$("$@" 2>"$WORKDIR/stderr")"
  rc=$?
  err="$(cat "$WORKDIR/stderr")"

  local note=""
  if (( rc != expected )); then
    note="rc=$rc (expected $expected)"
  fi
  if [[ -n "$needle" && "$err" != *"$needle"* ]]; then
    note="${note:+$note; }stderr missing '$needle': $err"
  fi
  if [[ -n "$out_needle" && "$out" != *"$out_needle"* ]]; then
    note="${note:+$note; }stdout missing '$out_needle': $out"
  fi

  if [[ -z "$note" ]]; then
    printf 'PASS  %s  %s\n' "$id" "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s  %s  [%s]\n' "$id" "$desc" "$note"
    fail=$((fail + 1))
    failures+=("$id $desc :: $note")
  fi
  unset STDERR_CONTAINS STDOUT_CONTAINS
}

# --- 1. git happy paths ---
run_case 01 "git status happy" 0 -- "$CEREBRO_BIN" git "$REPO" status

run_case 02 "git log --oneline happy" 0 -- "$CEREBRO_BIN" git "$REPO" log --oneline -n 1

run_case 03 "git diff HEAD~1 HEAD happy" 0 -- "$CEREBRO_BIN" git "$REPO" diff HEAD~1 HEAD

# --- 4. denied git subcommand ---
STDERR_CONTAINS="not on allow-list" \
run_case 04 "git commit denied" 4 -- "$CEREBRO_BIN" git "$REPO" commit -m x

# --- 5. denied git flag (branch mutate) ---
STDERR_CONTAINS="mutating flag" \
run_case 05 "git branch -d denied" 5 -- "$CEREBRO_BIN" git "$REPO" branch -d main

# --- 6. denied git config write (positional with no --get) ---
STDERR_CONTAINS="missing --get" \
run_case 06 "git config user.email x@y denied" 5 -- "$CEREBRO_BIN" git "$REPO" config user.email x@y

# --- 7. denied global git flag (subcommand position is a flag) ---
STDERR_CONTAINS="subcommand position cannot be a flag" \
run_case 07 "git -c foo=bar log denied" 5 -- "$CEREBRO_BIN" git "$REPO" -c foo=bar log

# --- 8. shell metachars are inert (no shell in the exec path) ---
"$CEREBRO_BIN" git "$REPO" log ';foo;' >/dev/null 2>"$WORKDIR/stderr"
err="$(cat "$WORKDIR/stderr")"
if [[ "$err" != *"shell metacharacter"* ]]; then
  printf 'PASS  08  shell-metachar arg reaches git\n'
  pass=$((pass + 1))
else
  printf 'FAIL  08  bridge still rejects shell metachars: %s\n' "$err"
  fail=$((fail + 1))
  failures+=("08 :: $err")
fi

# --- 9. non-repo path ---
STDERR_CONTAINS="not a git repo" \
run_case 09 "git /tmp status (not a repo)" 3 -- "$CEREBRO_BIN" git /tmp status

# --- 10. non-absolute path ---
STDERR_CONTAINS="must be absolute" \
run_case 10 "git relative status" 3 -- "$CEREBRO_BIN" git relative status

# --- 11. denied gh write ---
STDERR_CONTAINS="not allow-listed" \
run_case 11 "gh pr create denied" 4 -- "$CEREBRO_BIN" gh "$REPO" pr create

# --- 12. denied gh api method ---
STDERR_CONTAINS="write flag" \
run_case 12 "gh api -X POST denied" 5 -- "$CEREBRO_BIN" gh "$REPO" api -X POST /repos/x/y

# --- 13. denied gh write (gist create); gist list itself is allow-listed ---
STDERR_CONTAINS="not allow-listed" \
run_case 13 "gh gist create denied" 4 -- "$CEREBRO_BIN" gh "$REPO" gist create

# --- 14. read happy ---
run_case 14 "read a.txt happy" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt

# --- 15. read escape ---
STDERR_CONTAINS="path escapes repo" \
run_case 15 "read ../etc/passwd denied" 6 -- "$CEREBRO_BIN" read "$REPO" ../etc/passwd

# --- 16. read non-file: benign by default (marker + exit 0) ---
STDOUT_CONTAINS="(not found:" \
run_case 16 "read . (directory) benign miss" 0 -- "$CEREBRO_BIN" read "$REPO" .

# --- 16b. read non-file --strict-missing restores exit 3 ---
STDERR_CONTAINS="not a regular file" \
run_case 16b "read . (directory) --strict-missing" 3 -- "$CEREBRO_BIN" read "$REPO" . --strict-missing

# --- 16c. read missing in-repo file: benign by default ---
STDOUT_CONTAINS="(not found:" \
run_case 16c "read no/such/file.txt benign miss" 0 -- "$CEREBRO_BIN" read "$REPO" no/such/file.txt

# --- 16d. read missing in-repo file --strict-missing ---
STDERR_CONTAINS="not a regular file" \
run_case 16d "read no/such/file.txt --strict-missing" 3 -- "$CEREBRO_BIN" read "$REPO" no/such/file.txt --strict-missing

# --- 17. grep zero matches: benign by default ('(no matches)' + exit 0) ---
if command -v rg >/dev/null 2>&1; then
  STDOUT_CONTAINS="(no matches)" \
  run_case 17 "grep zero-match benign" 0 -- "$CEREBRO_BIN" grep "$REPO" 'something'
else
  printf 'SKIP  17  grep zero-match (rg not installed)\n'
fi

# --- 17b. grep with NO flag args (regression for nounset + empty rg_args) ---
if command -v rg >/dev/null 2>&1; then
  STDOUT_CONTAINS="(no matches)" \
  run_case 17b "grep no-flag-args zero-match benign" 0 -- "$CEREBRO_BIN" grep "$REPO" 'no-such-literal'
fi

# --- 17c. grep zero matches --strict-missing restores rg-native exit 1 ---
if command -v rg >/dev/null 2>&1; then
  run_case 17c "grep zero-match --strict-missing (rg exit 1)" 1 -- "$CEREBRO_BIN" grep "$REPO" 'something' --strict-missing
fi

# --- 17d. grep bad regex: genuine rg error stays hard (rc >= 2) ---
if command -v rg >/dev/null 2>&1; then
  "$CEREBRO_BIN" grep "$REPO" '(' >/dev/null 2>&1
  rc=$?
  if [[ $rc -ge 2 ]]; then
    printf 'PASS  17d  grep bad-regex stays hard (rc=%d)\n' "$rc"
    pass=$((pass + 1))
  else
    printf 'FAIL  17d  grep bad-regex [rc=%d expected >=2]\n' "$rc"
    fail=$((fail + 1))
    failures+=("17d grep bad-regex :: rc=$rc")
  fi
fi

# --- 18. grep escape ---
STDERR_CONTAINS="path escapes repo" \
run_case 18 "grep --path ../.. escape denied" 6 -- "$CEREBRO_BIN" grep "$REPO" foo --path ../..

# --- 19. ls happy ---
out="$("$CEREBRO_BIN" ls "$REPO" 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"a.txt"* ]]; then
  printf 'PASS  19  ls happy (lists a.txt)\n'
  pass=$((pass + 1))
else
  printf 'FAIL  19  ls happy [rc=%d out=%s]\n' "$rc" "$out"
  fail=$((fail + 1))
  failures+=("19 ls happy :: rc=$rc out=$out")
fi

# --- 20. ls escape ---
STDERR_CONTAINS="path escapes repo" \
run_case 20 "ls ../.. escape denied" 6 -- "$CEREBRO_BIN" ls "$REPO" ../..

# --- 20b. ls missing in-repo dir: benign by default ---
STDOUT_CONTAINS="(not found:" \
run_case 20b "ls no/such/dir benign miss" 0 -- "$CEREBRO_BIN" ls "$REPO" no/such/dir

# --- 20c. ls missing in-repo dir --strict-missing ---
STDERR_CONTAINS="not a directory" \
run_case 20c "ls no/such/dir --strict-missing" 3 -- "$CEREBRO_BIN" ls "$REPO" no/such/dir --strict-missing

# --- 20d. ls bare-abs missing path: benign by default (exit-7 routing) ---
STDOUT_CONTAINS="(not found:" \
run_case 20d "ls bare-abs missing benign" 0 -- "$CEREBRO_BIN" ls "$WORKDIR/does-not-exist"

# --- 20e. ls bare-abs missing path --strict-missing ---
STDERR_CONTAINS="not found" \
run_case 20e "ls bare-abs missing --strict-missing" 3 -- "$CEREBRO_BIN" ls "$WORKDIR/does-not-exist" --strict-missing

# --- 21. unknown top-level subcommand ---
STDERR_CONTAINS="unknown subcommand" \
run_case 21 "cerebro doesnotexist" 1 -- "$CEREBRO_BIN" doesnotexist

# --- 22. read outside repo (not a git worktree): benign by default ---
STDOUT_CONTAINS="(not found:" \
run_case 22 "read /etc passwd (not a worktree) benign" 0 -- "$CEREBRO_BIN" read /etc passwd

# --- 22b. read /etc passwd --strict-missing restores exit 3 ---
STDERR_CONTAINS="not a git worktree" \
run_case 22b "read /etc passwd --strict-missing" 3 -- "$CEREBRO_BIN" read /etc passwd --strict-missing

# --- 23. grep bare-abs: pattern required (no worktree, but pattern missing) ---
STDERR_CONTAINS="usage" \
run_case 23 "grep /etc (no pattern) usage error" 2 -- "$CEREBRO_BIN" grep /etc

# Pre-create a directory the bare-abs cases below can read out of.
mkdir -p "$WORKDIR/lookups"
printf 'findme\n' > "$WORKDIR/lookups/needle.txt"

# --- 24. ls bare-abs against a directory the sandbox controls ---
out="$("$CEREBRO_BIN" ls "$WORKDIR/lookups" 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"needle.txt"* ]]; then
  printf 'PASS  24  ls bare-abs (lists needle.txt)\n'
  pass=$((pass + 1))
else
  printf 'FAIL  24  ls bare-abs [rc=%d out=%s]\n' "$rc" "$out"
  fail=$((fail + 1))
  failures+=("24 ls bare-abs :: rc=$rc out=$out")
fi

# --- 25. git symbolic-ref SET form denied (read form is allowed; see 73) ---
STDERR_CONTAINS="SET form" \
run_case 25 "git symbolic-ref SET form denied" 5 -- "$CEREBRO_BIN" git "$REPO" symbolic-ref HEAD refs/heads/x

# --- 26. git remote add denied ---
STDERR_CONTAINS="git remote" \
run_case 26 "git remote add denied" 5 -- "$CEREBRO_BIN" git "$REPO" remote add foo http://example/

# --- 27. git remote -v add smuggle denied ---
STDERR_CONTAINS="git remote: mutating action" \
run_case 27 "git remote -v add denied" 5 -- "$CEREBRO_BIN" git "$REPO" remote -v add foo http://example/

# --- 28. git remote set-url denied ---
STDERR_CONTAINS="git remote: mutating action" \
run_case 28 "git remote set-url denied" 5 -- "$CEREBRO_BIN" git "$REPO" remote set-url origin foo

# --- 29. git diff --no-index denied ---
STDERR_CONTAINS="no-index" \
run_case 29 "git diff --no-index denied" 5 -- "$CEREBRO_BIN" git "$REPO" diff --no-index /etc/passwd /etc/hosts

# --- 30. git blame --contents denied ---
STDERR_CONTAINS="contents" \
run_case 30 "git blame --contents denied" 5 -- "$CEREBRO_BIN" git "$REPO" blame --contents /etc/passwd HEAD --

# --- 31. git config --file denied ---
STDERR_CONTAINS="git config" \
run_case 31 "git config --file /etc/passwd denied" 5 -- "$CEREBRO_BIN" git "$REPO" config --file /etc/passwd --get foo

# --- 32. git config --global denied ---
STDERR_CONTAINS="git config" \
run_case 32 "git config --global denied" 5 -- "$CEREBRO_BIN" git "$REPO" config --global --get user.email

# --- 33. git ls-files --exclude-from denied ---
STDERR_CONTAINS="ls-files" \
run_case 33 "git ls-files --exclude-from denied" 5 -- "$CEREBRO_BIN" git "$REPO" ls-files --exclude-from /etc/passwd

# --- 34. gh api -XPOST attached short denied ---
STDERR_CONTAINS="write flag" \
run_case 34 "gh api -XPOST denied (attached)" 5 -- "$CEREBRO_BIN" gh "$REPO" api -XPOST /repos/x/y

# --- 35. gh api -Ffoo=bar attached short denied ---
STDERR_CONTAINS="write flag" \
run_case 35 "gh api -Ffoo=bar denied (attached)" 5 -- "$CEREBRO_BIN" gh "$REPO" api -Ffoo=bar /repos/x/y

# --- 36. gh api -ffoo=bar attached short denied ---
STDERR_CONTAINS="write flag" \
run_case 36 "gh api -ffoo=bar denied (attached)" 5 -- "$CEREBRO_BIN" gh "$REPO" api -ffoo=bar /repos/x/y

# --- 37. gh api --method=POST attached long denied ---
STDERR_CONTAINS="write flag" \
run_case 37 "gh api --method=POST denied (attached)" 5 -- "$CEREBRO_BIN" gh "$REPO" api --method=POST /repos/x/y

# --- 38. git config --list defaults to local (succeeds) ---
run_case 38 "git config --list happy (forced --local)" 0 -- "$CEREBRO_BIN" git "$REPO" config --list

# --- 39. git config -fpath attached form denied ---
STDERR_CONTAINS="git config" \
run_case 39 "git config -f/etc/passwd denied (attached)" 5 -- "$CEREBRO_BIN" git "$REPO" config -f/etc/passwd --get foo

# --- 40. git config --file=/etc/passwd attached form denied ---
STDERR_CONTAINS="git config" \
run_case 40 "git config --file=/etc/passwd denied (attached)" 5 -- "$CEREBRO_BIN" git "$REPO" config --file=/etc/passwd --get foo

# --- 41/42. .git/index left untouched by read-only bridge ---
# We poke a workdir file's mtime so a stat-only refresh of the index would
# otherwise happen. With `--no-optional-locks` plumbed into the bridge,
# `git status` skips the lazy index rewrite. (`git diff` upstream still
# refreshes the index when stat info is stale even with --no-optional-locks,
# so we exercise diff without the artificial mtime poke -- under realistic
# use the bridge must not touch the index there either.)
stat_index() {
  python3 - "$REPO/.git/index" <<'PY'
import os, sys
s = os.stat(sys.argv[1])
print(s.st_mtime_ns, s.st_ino, s.st_size)
PY
}

touch -t 202001010000 "$REPO/a.txt"
before_status="$(stat_index)"
"$CEREBRO_BIN" git "$REPO" status >/dev/null 2>&1
after_status="$(stat_index)"
if [[ "$before_status" == "$after_status" ]]; then
  printf 'PASS  41  git status leaves .git/index untouched\n'
  pass=$((pass + 1))
else
  printf 'FAIL  41  git status mutated .git/index [before=%s after=%s]\n' \
    "$before_status" "$after_status"
  fail=$((fail + 1))
  failures+=("41 git status leaves .git/index untouched :: before=$before_status after=$after_status")
fi

# Settle the index after the status path (also clears any pending stat
# discrepancy from earlier tests) before sampling for the diff test.
git -C "$REPO" update-index --refresh >/dev/null 2>&1 || true
before_diff="$(stat_index)"
"$CEREBRO_BIN" git "$REPO" diff >/dev/null 2>&1
after_diff="$(stat_index)"
if [[ "$before_diff" == "$after_diff" ]]; then
  printf 'PASS  42  git diff leaves .git/index untouched\n'
  pass=$((pass + 1))
else
  printf 'FAIL  42  git diff mutated .git/index [before=%s after=%s]\n' \
    "$before_diff" "$after_diff"
  fail=$((fail + 1))
  failures+=("42 git diff leaves .git/index untouched :: before=$before_diff after=$after_diff")
fi

# --- 43-46. external-helper flags refused on read-only subcommands ---
STDERR_CONTAINS="external helper flag" \
run_case 43 "git diff --ext-diff denied" 5 -- "$CEREBRO_BIN" git "$REPO" diff --ext-diff
STDERR_CONTAINS="external helper flag" \
run_case 44 "git log --textconv denied" 5 -- "$CEREBRO_BIN" git "$REPO" log --textconv
STDERR_CONTAINS="external helper flag" \
run_case 45 "git show --filters denied" 5 -- "$CEREBRO_BIN" git "$REPO" show --filters
STDERR_CONTAINS="external helper flag" \
run_case 46 "git blame --textconv denied" 5 -- "$CEREBRO_BIN" git "$REPO" blame --textconv a.txt

# --- 47. positive: diff still works when repo config sets diff.external=/bin/false ---
# Without the `--no-ext-diff` injection (or with a working override), an
# attacker-controlled `.git/config` could redirect every diff through an
# arbitrary program. The bridge must produce normal diff output here.
git -C "$REPO" config diff.external /bin/false
echo "tampered" > "$REPO/a.txt"
diff_out="$("$CEREBRO_BIN" git "$REPO" diff -- a.txt 2>"$WORKDIR/stderr")"
diff_rc=$?
diff_err="$(cat "$WORKDIR/stderr")"
git -C "$REPO" config --unset diff.external
if [[ $diff_rc -eq 0 && "$diff_out" == *"+tampered"* && "$diff_err" != *"external diff"* ]]; then
  printf 'PASS  47  git diff bypasses repo diff.external=/bin/false\n'
  pass=$((pass + 1))
else
  printf 'FAIL  47  git diff with diff.external=/bin/false [rc=%d out=%s err=%s]\n' \
    "$diff_rc" "$diff_out" "$diff_err"
  fail=$((fail + 1))
  failures+=("47 diff.external bypass :: rc=$diff_rc out=$diff_out err=$diff_err")
fi
# Restore a.txt so later test rounds see a clean tree.
git -C "$REPO" checkout -q -- a.txt 2>/dev/null || true

# --- 48-50. gh happy paths via a PATH stub ---
# We can't (and don't want to) call the real `gh` from tests. Drop a stub on
# PATH that records argv to a file, then assert each allowed dispatch reaches
# the stub with the expected argv. This guards the actual exec path -- denial
# tests alone would miss a regression that broke `exec gh "$top" "$@"`.
GH_STUB_DIR="$WORKDIR/gh-stub"
mkdir -p "$GH_STUB_DIR"
GH_ARGV_LOG="$WORKDIR/gh-argv.log"
cat > "$GH_STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_ARGV_LOG"
exit 0
EOF
chmod +x "$GH_STUB_DIR/gh"

gh_happy() {
  local id="$1" desc="$2" expected_argv="$3"; shift 3
  : > "$GH_ARGV_LOG"
  PATH="$GH_STUB_DIR:$PATH" "$CEREBRO_BIN" gh "$REPO" "$@" >/dev/null 2>"$WORKDIR/stderr"
  local rc=$?
  local got; got="$(cat "$GH_ARGV_LOG" 2>/dev/null)"
  if [[ $rc -eq 0 && "$got" == "$expected_argv" ]]; then
    printf 'PASS  %s  %s\n' "$id" "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s  %s [rc=%d argv=%q expected=%q]\n' \
      "$id" "$desc" "$rc" "$got" "$expected_argv"
    fail=$((fail + 1))
    failures+=("$id $desc :: rc=$rc argv=$got expected=$expected_argv")
  fi
}

gh_happy 48 "gh pr view 123 dispatches" "pr view 123"        pr view 123
gh_happy 49 "gh pr list --limit 5 dispatches" "pr list --limit 5" pr list --limit 5
gh_happy 50 "gh api /repos/foo/bar dispatches" "api /repos/foo/bar" api /repos/foo/bar

# --- 51. shell metachars pass through to gh (jq -q with commas/parens) ---
gh_happy 51 "gh pr view --json with -q containing commas/parens/spaces" \
  "pr view 64 --json baseRefName,headRefName,commits -q .baseRefName, .headRefName, (.commits | length)" \
  pr view 64 --json baseRefName,headRefName,commits -q ".baseRefName, .headRefName, (.commits | length)"

# ========================================================================
# Category A coverage (52-63): forgiving argv shapes for read/grep/ls.
# ========================================================================

# --- 52. read abs file path infers enclosing repo ---
out="$("$CEREBRO_BIN" read "$REPO/a.txt" --range 1:1 2>"$WORKDIR/stderr")"
rc=$?
err="$(cat "$WORKDIR/stderr")"
if [[ $rc -eq 0 && "$err" == *"inferred repo"* ]]; then
  printf 'PASS  52  read with abs file path infers repo\n'
  pass=$((pass + 1))
else
  printf 'FAIL  52  read abs-file repo-infer [rc=%d err=%s]\n' "$rc" "$err"
  fail=$((fail + 1))
  failures+=("52 read abs-file repo-infer :: rc=$rc err=$err")
fi

# --- 53. read abs file no flag (legacy file form ok) ---
run_case 53 "read abs file no flag happy" 0 -- "$CEREBRO_BIN" read "$REPO/a.txt"

# --- 54. read --range N-M ---
run_case 54 "read --range N-M" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt --range 1-1

# --- 55. read --range N..M ---
run_case 55 "read --range N..M" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt --range 1..1

# --- 56. read --range N M (two ints) ---
run_case 56 "read --range N M" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt --range 1 1

# --- 57. read --from N --to M ---
run_case 57 "read --from N --to M" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt --from 1 --to 1

# --- 58. read --range N (open-ended) ---
run_case 58 "read --range bare-N" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt --range 1

# --- 59. read ./a.txt ---
run_case 59 "read ./a.txt" 0 -- "$CEREBRO_BIN" read "$REPO" ./a.txt

# --- 60. read bogus --range value emits canonical hint ---
STDERR_CONTAINS="canonical: --range" \
run_case 60 "read bad --range value with hint" 2 -- "$CEREBRO_BIN" read "$REPO" a.txt --range abc

# --- 61. grep --type rs aliased to rust ---
if command -v rg >/dev/null 2>&1; then
  "$CEREBRO_BIN" grep "$REPO" 'pattern' --type rs >/dev/null 2>"$WORKDIR/stderr"
  rc=$?
  err="$(cat "$WORKDIR/stderr")"
  if [[ ( $rc -eq 0 || $rc -eq 1 ) && "$err" != *"unrecognized file type"* ]]; then
    printf 'PASS  61  grep --type rs aliased to rust (rc=%d)\n' "$rc"
    pass=$((pass + 1))
  else
    printf 'FAIL  61  grep --type rs alias [rc=%d err=%s]\n' "$rc" "$err"
    fail=$((fail + 1))
    failures+=("61 grep --type rs alias :: rc=$rc err=$err")
  fi
else
  printf 'SKIP  61  grep --type rs aliased (rg not installed)\n'
fi

# --- 62. grep --type yml aliased to yaml ---
if command -v rg >/dev/null 2>&1; then
  "$CEREBRO_BIN" grep "$REPO" 'pattern' --type yml >/dev/null 2>"$WORKDIR/stderr"
  rc=$?
  err="$(cat "$WORKDIR/stderr")"
  if [[ ( $rc -eq 0 || $rc -eq 1 ) && "$err" != *"unrecognized file type"* ]]; then
    printf 'PASS  62  grep --type yml aliased to yaml (rc=%d)\n' "$rc"
    pass=$((pass + 1))
  else
    printf 'FAIL  62  grep --type yml alias [rc=%d err=%s]\n' "$rc" "$err"
    fail=$((fail + 1))
    failures+=("62 grep --type yml alias :: rc=$rc err=$err")
  fi
else
  printf 'SKIP  62  grep --type yml aliased (rg not installed)\n'
fi

# --- 63. grep unknown arg with canonical hint ---
STDERR_CONTAINS="canonical: cerebro grep" \
run_case 63 "grep unknown arg with hint" 2 -- "$CEREBRO_BIN" grep "$REPO" foo --nope

# ========================================================================
# Category B coverage (64-73d): broadened git allow-list.
# ========================================================================

run_case 64 "git rev-list HEAD happy" 0 -- "$CEREBRO_BIN" git "$REPO" rev-list -n 1 HEAD
run_case 65 "git count-objects happy" 0 -- "$CEREBRO_BIN" git "$REPO" count-objects
run_case 66 "git show-ref happy" 0 -- "$CEREBRO_BIN" git "$REPO" show-ref
run_case 67 "git check-ref-format happy" 0 -- "$CEREBRO_BIN" git "$REPO" check-ref-format refs/heads/main
run_case 68 "git var GIT_EDITOR happy" 0 -- "$CEREBRO_BIN" git "$REPO" var GIT_EDITOR
run_case 69 "git diff-tree happy" 0 -- "$CEREBRO_BIN" git "$REPO" diff-tree -r HEAD
run_case 70 "git range-diff self happy" 0 -- "$CEREBRO_BIN" git "$REPO" range-diff HEAD~1..HEAD HEAD~1..HEAD

# --- 71. git archive --output denied (matched by global deny-list) ---
STDERR_CONTAINS="denied global flag: --output" \
run_case 71 "git archive --output denied" 5 -- "$CEREBRO_BIN" git "$REPO" archive --output /tmp/x.tar HEAD

# --- 72. git hash-object -w denied ---
STDERR_CONTAINS="-w writes" \
run_case 72 "git hash-object -w denied" 5 -- \
  bash -c "printf x | '$CEREBRO_BIN' git '$REPO' hash-object -w --stdin"

# --- 73. git symbolic-ref read form happy ---
run_case 73 "git symbolic-ref read form happy" 0 -- "$CEREBRO_BIN" git "$REPO" symbolic-ref HEAD

# --- 73b. git apply requires --check ---
STDERR_CONTAINS="only --check form allowed" \
run_case 73b "git apply without --check denied" 5 -- "$CEREBRO_BIN" git "$REPO" apply some.patch

# --- 73c. git fetch reaches git (allow-list + no mutating flags) ---
"$CEREBRO_BIN" git "$REPO" fetch >/dev/null 2>"$WORKDIR/stderr"
rc=$?
err="$(cat "$WORKDIR/stderr")"
if [[ "$err" != *"not on allow-list"* && "$err" != *"mutating flag"* && "$err" != *"denied global flag"* ]]; then
  printf 'PASS  73c  git fetch reaches git (rc=%d)\n' "$rc"
  pass=$((pass + 1))
else
  printf 'FAIL  73c  git fetch blocked by bridge [rc=%d err=%s]\n' "$rc" "$err"
  fail=$((fail + 1))
  failures+=("73c git fetch reaches git :: rc=$rc err=$err")
fi

# --- 73d. git fetch --prune denied ---
STDERR_CONTAINS="mutating flag: --prune" \
run_case 73d "git fetch --prune denied" 5 -- "$CEREBRO_BIN" git "$REPO" fetch --prune

# --- 73e. git fast-export --export-marks denied ---
STDERR_CONTAINS="mutating flag: --export-marks" \
run_case 73e "git fast-export --export-marks denied" 5 -- \
  "$CEREBRO_BIN" git "$REPO" fast-export --export-marks=/tmp/marks --all

# --- 73f. git replace positional SET form denied (no --list) ---
STDERR_CONTAINS="positional arg without --list" \
run_case 73f "git replace SET form denied" 5 -- \
  "$CEREBRO_BIN" git "$REPO" replace HEAD HEAD~1

# --- 73g. git symbolic-ref --delete denied ---
STDERR_CONTAINS="mutating flag: --delete" \
run_case 73g "git symbolic-ref --delete denied" 5 -- \
  "$CEREBRO_BIN" git "$REPO" symbolic-ref --delete HEAD

# ========================================================================
# Category C coverage (74-83b): broadened gh allow-list (via PATH stub).
# ========================================================================

gh_happy 74 "gh workflow list dispatches" "workflow list" workflow list

STDERR_CONTAINS="not allow-listed" \
run_case 75 "gh workflow run denied" 4 -- "$CEREBRO_BIN" gh "$REPO" workflow run wf.yml

gh_happy 76 "gh secret list dispatches" "secret list" secret list

STDERR_CONTAINS="not allow-listed" \
run_case 77 "gh secret set denied" 4 -- "$CEREBRO_BIN" gh "$REPO" secret set NAME

gh_happy 78 "gh cache list dispatches" "cache list" cache list
gh_happy 79 "gh label list dispatches" "label list" label list
gh_happy 80 "gh codespace list dispatches" "codespace list" codespace list

# --- 80b. gh codespace ports (bare) dispatches ---
gh_happy 80b "gh codespace ports happy" "codespace ports" codespace ports

# --- 80c. gh codespace ports forward denied (nested mutating verb) ---
STDERR_CONTAINS="codespace ports" \
run_case 80c "gh codespace ports forward denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports forward 8080

# --- 80d. gh codespace ports visibility denied (nested mutating verb) ---
STDERR_CONTAINS="codespace ports" \
run_case 80d "gh codespace ports visibility denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports visibility 8080:private

# --- 80e. gh codespace ports -c <name> forward denied (flag-before-subcmd) ---
STDERR_CONTAINS="forward" \
run_case 80e "gh codespace ports -c name forward denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports -c some-name forward 8080:8080

# --- 80f. gh codespace ports --json visibility happy (visibility as JSON field) ---
gh_happy 80f "gh codespace ports --json visibility happy" \
  "codespace ports --json visibility" \
  codespace ports --json visibility

# --- 80g. gh codespace ports -c visibility forward denied (flag value skipped) ---
STDERR_CONTAINS="forward" \
run_case 80g "gh codespace ports -c visibility forward denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports -c visibility forward 8080:8080

# --- 80h. gh codespace ports --codespace=visibility happy (equals-form value) ---
gh_happy 80h "gh codespace ports --codespace=visibility happy" \
  "codespace ports --codespace=visibility" \
  codespace ports --codespace=visibility

# --- 80i. gh codespace ports --repo-owner <owner> forward denied (codex case) ---
STDERR_CONTAINS="forward" \
run_case 80i "gh codespace ports --repo-owner alice forward denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports --repo-owner alice forward 8080:8080

# --- 80j. gh codespace ports --repo-owner=alice happy (equals form is self-contained) ---
gh_happy 80j "gh codespace ports --repo-owner=alice happy" \
  "codespace ports --repo-owner=alice" \
  codespace ports --repo-owner=alice

# --- 80k. gh codespace ports --display-name <name> forward denied (audit-added flag) ---
STDERR_CONTAINS="forward" \
run_case 80k "gh codespace ports --display-name name forward denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports --display-name my-space forward 8080:8080

STDERR_CONTAINS="not allow-listed" \
run_case 81 "gh auth token denied" 4 -- "$CEREBRO_BIN" gh "$REPO" auth token

gh_happy 82 "gh config get editor dispatches" "config get editor" config get editor

STDERR_CONTAINS="runs arbitrary code" \
run_case 83 "gh extension install denied with reason" 4 -- "$CEREBRO_BIN" gh "$REPO" extension install owner/repo

STDERR_CONTAINS="side-effect" \
run_case 83b "gh browse top-level denied" 4 -- "$CEREBRO_BIN" gh "$REPO" browse

# ========================================================================
# Category D coverage (84-92): bare-abs read/grep/ls.
# ========================================================================

# Sandbox-local file outside any worktree.
printf 'hello\n' > "$WORKDIR/outside.txt"

# --- 84. read bare-abs file happy ---
out="$("$CEREBRO_BIN" read "$WORKDIR/outside.txt" 2>"$WORKDIR/stderr")"
rc=$?
if [[ $rc -eq 0 && "$out" == *"hello"* ]]; then
  printf 'PASS  84  read bare-abs file happy\n'
  pass=$((pass + 1))
else
  printf 'FAIL  84  read bare-abs file happy [rc=%d out=%s]\n' "$rc" "$out"
  fail=$((fail + 1))
  failures+=("84 read bare-abs file :: rc=$rc out=$out")
fi

# --- 85. read bare-abs file with --range ---
run_case 85 "read bare-abs --range" 0 -- "$CEREBRO_BIN" read "$WORKDIR/outside.txt" --range 1:1

# --- 86. read bare-abs special path: security refusal stays hard (exit 6) ---
STDERR_CONTAINS="special path" \
run_case 86 "read /dev/null denied (security)" 6 -- "$CEREBRO_BIN" read /dev/null

# --- 87. read bare-abs another special path: security refusal stays hard ---
STDERR_CONTAINS="special path" \
run_case 87 "read /dev/tty denied (under /dev/)" 6 -- "$CEREBRO_BIN" read /dev/tty

# --- 88. read bare-abs nonexistent: benign by default (exit-7 routing) ---
STDOUT_CONTAINS="(not found:" \
run_case 88 "read nonexistent bare-abs benign" 0 -- "$CEREBRO_BIN" read /no/such/path/xyz

# --- 88b. read bare-abs nonexistent --strict-missing restores exit 3 ---
STDERR_CONTAINS="not found" \
run_case 88b "read nonexistent bare-abs --strict-missing" 3 -- "$CEREBRO_BIN" read /no/such/path/xyz --strict-missing

# --- 89. grep bare-abs happy (sandbox dir) ---
if command -v rg >/dev/null 2>&1; then
  out="$("$CEREBRO_BIN" grep "$WORKDIR/lookups" findme 2>/dev/null)"
  rc=$?
  if [[ ( $rc -eq 0 || $rc -eq 1 ) && "$out" == *"needle.txt"*"findme"* ]]; then
    printf 'PASS  89  grep bare-abs happy\n'
    pass=$((pass + 1))
  else
    printf 'FAIL  89  grep bare-abs happy [rc=%d out=%s]\n' "$rc" "$out"
    fail=$((fail + 1))
    failures+=("89 grep bare-abs happy :: rc=$rc out=$out")
  fi
else
  printf 'SKIP  89  grep bare-abs happy (rg not installed)\n'
fi

# --- 90. grep bare-abs missing pattern ---
STDERR_CONTAINS="usage" \
run_case 90 "grep bare-abs missing pattern" 2 -- "$CEREBRO_BIN" grep "$WORKDIR/lookups"

# --- 91. ls bare-abs happy ---
out="$("$CEREBRO_BIN" ls "$WORKDIR/lookups" 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"needle.txt"* ]]; then
  printf 'PASS  91  ls bare-abs lists needle.txt\n'
  pass=$((pass + 1))
else
  printf 'FAIL  91  ls bare-abs [rc=%d out=%s]\n' "$rc" "$out"
  fail=$((fail + 1))
  failures+=("91 ls bare-abs :: rc=$rc out=$out")
fi

# --- 92. ls bare-abs special path: security refusal stays hard (exit 6) ---
STDERR_CONTAINS="special path" \
run_case 92 "ls /dev denied (security)" 6 -- "$CEREBRO_BIN" ls /dev

# ========================================================================
# apply-review default-findings and staleness validation.
# These validation paths fire BEFORE any child spawn, so the error cases need
# no opencode. The happy cases install an `opencode` PATH stub that emits one
# successful `run --format json` turn, so apply-review completes.
# ========================================================================

SESS_DIR="$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID"
RSTATE="$SESS_DIR/review-state"
CHILDREN="$SESS_DIR/children"
# Per-repo key the same way cerebro computes it: sha1 of the canonical
# worktree root, first 16 hex.
RKEY="$(git -C "$REPO" rev-parse --show-toplevel \
        | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().strip().encode()).hexdigest()[:16])')"
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"

# opencode stub: emit one successful `run --format json` turn, exit 0. The
# child prompt arrives as the last positional argument (not on stdin).
OPENCODE_STUB_DIR="$WORKDIR/opencode-stub"
mkdir -p "$OPENCODE_STUB_DIR"
cat > "$OPENCODE_STUB_DIR/opencode" <<'EOF'
#!/usr/bin/env bash
sid="STUBSESS-1"
printf '{"type":"step_start","sessionID":"%s","part":{"type":"step-start"}}\n' "$sid"
printf '{"type":"text","sessionID":"%s","part":{"type":"text","text":"ok"}}\n' "$sid"
printf '{"type":"step_finish","sessionID":"%s","part":{"type":"step-finish","reason":"stop"}}\n' "$sid"
exit 0
EOF
chmod +x "$OPENCODE_STUB_DIR/opencode"
STUB_OK=0; [[ -x "$OPENCODE_STUB_DIR/opencode" ]] && STUB_OK=1
STUB_PATH="$OPENCODE_STUB_DIR:$PATH"

seed_review_state() {  # $1 = last_findings path
  mkdir -p "$RSTATE"
  jq -n --arg repo "$(git -C "$REPO" rev-parse --show-toplevel)" \
        --arg branch "$BRANCH" --arg sha "$(git -C "$REPO" rev-parse HEAD)" \
        --arg findings "$1" --arg ts "2026-01-01T00:00:00Z" \
        '{repo:$repo, branch:$branch, last_reviewed_sha:$sha, last_findings:$findings, ts:$ts}' \
        > "$RSTATE/$RKEY.json"
}

# --- 93. apply-review with no findings defaults to last review's findings ---
if (( STUB_OK )); then
  printf 'review findings here\n' > "$CHILDREN/review-TEST.md"
  seed_review_state "$CHILDREN/review-TEST.md"
  STDERR_CONTAINS="defaulting to last review findings" \
  run_case 93 "apply-review defaults to last review findings" 0 -- \
    env PATH="$STUB_PATH" "$CEREBRO_BIN" apply-review "$REPO"
else
  printf 'SKIP  93  apply-review default findings (opencode stub unavailable)\n'
fi

# --- 94. apply-review, no findings + no prior review -> clear error ---
rm -f "$RSTATE/$RKEY.json"
STDERR_CONTAINS="no prior review for this repo+branch" \
run_case 94 "apply-review no findings, no prior review errors" 1 -- \
  "$CEREBRO_BIN" apply-review "$REPO"

# --- 95. nonexistent explicit findings names the correct last-review path ---
seed_review_state "$CHILDREN/review-TEST.md"
STDERR_CONTAINS="the last review for this repo+branch is:" \
run_case 95 "apply-review bad explicit findings names latest" 1 -- \
  "$CEREBRO_BIN" apply-review "$REPO" /no/such/findings.md

# --- 96. stale (older) findings warns non-fatally but still applies ---
if (( STUB_OK )); then
  printf 'older findings\n' > "$WORKDIR/older.md"
  seed_review_state "$CHILDREN/review-TEST.md"   # newest != older.md
  STDERR_CONTAINS="not the latest review" \
  run_case 96 "apply-review stale findings warns, applies" 0 -- \
    env PATH="$STUB_PATH" "$CEREBRO_BIN" apply-review "$REPO" "$WORKDIR/older.md"
else
  printf 'SKIP  96  apply-review stale findings (opencode stub unavailable)\n'
fi

# --- 99. regression: --notes with --prompt still rejected ---
STDERR_CONTAINS="only meaningful with a findings file" \
run_case 99 "apply-review --notes + --prompt still errors" 1 -- \
  "$CEREBRO_BIN" apply-review "$REPO" --prompt "x" --notes "y"

# --- 100. --prompt with NO operand is a usage error, never a findings fallback.
# Seed a valid last review so a buggy fallback WOULD succeed; the guard must
# still reject the empty --prompt rather than silently apply those findings.
printf 'seeded findings\n' > "$CHILDREN/review-TEST.md"
seed_review_state "$CHILDREN/review-TEST.md"
STDERR_CONTAINS="--prompt requires a non-empty value" \
run_case 100 "apply-review --prompt (no value) errors, no findings fallback" 1 -- \
  "$CEREBRO_BIN" apply-review "$REPO" --prompt

# --- 100b. --prompt "" (explicit empty operand) is likewise a usage error. ---
seed_review_state "$CHILDREN/review-TEST.md"
STDERR_CONTAINS="--prompt requires a non-empty value" \
run_case 100b "apply-review --prompt '' errors, no findings fallback" 1 -- \
  "$CEREBRO_BIN" apply-review "$REPO" --prompt ""

# --- 102. explicit-findings staleness check must NOT cross branches. ---
# Seed review state on the current branch naming review-TEST.md, then switch
# to a new branch and apply a DIFFERENT (older) findings file. The stored
# state belongs to the other branch, so cerebro must not name review-TEST.md
# as "latest for this repo+branch".
if (( STUB_OK )); then
  printf 'older findings\n' > "$WORKDIR/older2.md"
  seed_review_state "$CHILDREN/review-TEST.md"   # state recorded for $BRANCH
  git -C "$REPO" checkout -q -b other-branch
  out="$(env PATH="$STUB_PATH" "$CEREBRO_BIN" apply-review "$REPO" "$WORKDIR/older2.md" 2>"$WORKDIR/stderr")"
  rc=$?
  err="$(cat "$WORKDIR/stderr")"
  git -C "$REPO" checkout -q "$BRANCH"
  if [[ $rc -eq 0 && "$err" != *"not the latest review"* && "$err" != *"review-TEST.md"* ]]; then
    printf 'PASS  102  staleness naming does not cross branches\n'; pass=$((pass + 1))
  else
    printf 'FAIL  102  staleness check crossed branches [rc=%d err=%s]\n' "$rc" "$err"
    fail=$((fail + 1))
    failures+=("102 branch-cross staleness :: rc=$rc err=$err")
  fi
else
  printf 'SKIP  102  apply-review branch-switch staleness (opencode stub unavailable)\n'
fi

# ========================================================================
# 103. Concurrent mutating runs must write to DISTINCT child-log files.
# After dropping the per-repo lock, two same-session mutating ops can start
# within the same second. A bare <subcmd>-<ts> child-log name would let both
# tee into ONE file -> truncated/interleaved logs and an ambiguous echoed
# path. The child-log name is now collision-resistant (PID + random token),
# so each run gets its own file. We launch two apply-review ops concurrently
# (a stub that sleeps to force overlapping writes, tagging each emitted line
# with a per-run token), then assert the two echoed paths differ and that
# neither log shows the other run's token (no interleave/truncation).
# ========================================================================
if (( STUB_OK )); then
  CONC_STUB_DIR="$WORKDIR/conc-stub"
  mkdir -p "$CONC_STUB_DIR"
  cat > "$CONC_STUB_DIR/opencode" <<'EOF'
#!/usr/bin/env bash
# Echo back the per-run token carried in the prompt (last positional arg), many
# times over, so a shared child log would visibly interleave the two runs.
body="${!#}"
tok="$(printf '%s\n' "$body" | grep -o 'TOKEN=[A-Z]*' | head -1)"
tok="${tok#TOKEN=}"
sid="CONC-1"
sleep 0.4   # widen the window so both runs write concurrently
printf '{"type":"step_start","sessionID":"%s","part":{"type":"step-start"}}\n' "$sid"
for i in $(seq 1 300); do
  printf '{"type":"text","sessionID":"%s","tok":"%s","part":{"type":"text","text":"%d"}}\n' "$sid" "$tok" "$i"
done
printf '{"type":"step_finish","sessionID":"%s","part":{"type":"step-finish","reason":"stop"}}\n' "$sid"
exit 0
EOF
  chmod +x "$CONC_STUB_DIR/opencode"
  CONC_PATH="$CONC_STUB_DIR:$PATH"

  env PATH="$CONC_PATH" "$CEREBRO_BIN" apply-review "$REPO" \
    --prompt "do work TOKEN=AAAA" >"$WORKDIR/conc1.out" 2>/dev/null &
  c1=$!
  env PATH="$CONC_PATH" "$CEREBRO_BIN" apply-review "$REPO" \
    --prompt "do work TOKEN=BBBB" >"$WORKDIR/conc2.out" 2>/dev/null &
  c2=$!
  wait "$c1"; r1=$?
  wait "$c2"; r2=$?

  # The echoed child-log path is the final stdout line of each run.
  clog1="$(tail -1 "$WORKDIR/conc1.out")"
  clog2="$(tail -1 "$WORKDIR/conc2.out")"

  conc_ok=1; conc_why=""
  if (( r1 != 0 || r2 != 0 )); then
    conc_ok=0; conc_why="nonzero rc (r1=$r1 r2=$r2)"
  fi
  if [[ -z "$clog1" || -z "$clog2" || "$clog1" == "$clog2" ]]; then
    conc_ok=0; conc_why="${conc_why:+$conc_why; }child logs not distinct: '$clog1' vs '$clog2'"
  fi
  if [[ ! -f "$clog1" || ! -f "$clog2" ]]; then
    conc_ok=0; conc_why="${conc_why:+$conc_why; }child log file(s) missing"
  else
    a1="$(grep -c 'AAAA' "$clog1")"; b1="$(grep -c 'BBBB' "$clog1")"
    a2="$(grep -c 'AAAA' "$clog2")"; b2="$(grep -c 'BBBB' "$clog2")"
    if (( a1 != 300 || b1 != 0 || b2 != 300 || a2 != 0 )); then
      conc_ok=0
      conc_why="${conc_why:+$conc_why; }interleave/truncation (A1=$a1 B1=$b1 A2=$a2 B2=$b2)"
    fi
  fi

  if (( conc_ok )); then
    printf 'PASS  103  concurrent mutating runs use distinct child logs\n'
    pass=$((pass + 1))
  else
    printf 'FAIL  103  concurrent mutating runs collided [%s]\n' "$conc_why"
    fail=$((fail + 1))
    failures+=("103 concurrent child-log collision :: $conc_why")
  fi
else
  printf 'SKIP  103  concurrent child-log distinctness (opencode stub unavailable)\n'
fi

# ========================================================================
# 104-110. Preference learning: learn-note (pending journal), learn-set
# (active learnings, size-capped), and learnings (inspection). These files
# are global under $CEREBRO_HOME and persist across sessions.
# ========================================================================
LEARN_ACTIVE="$CEREBRO_HOME/learnings.md"
LEARN_PENDING="$CEREBRO_HOME/pending-learnings.md"

# --- 104. learnings on a clean home reports none ---
STDOUT_CONTAINS="(none yet)" \
run_case 104 "learnings empty reports none" 0 -- "$CEREBRO_BIN" learnings

# --- 105. learn-note appends to the pending journal ---
run_case 105 "learn-note records a signal" 0 -- \
  "$CEREBRO_BIN" learn-note "user repeatedly asks to simplify"
if [[ -s "$LEARN_PENDING" ]] && grep -q "user repeatedly asks to simplify" "$LEARN_PENDING"; then
  printf 'PASS  105b  learn-note wrote pending journal\n'; pass=$((pass + 1))
else
  printf 'FAIL  105b  learn-note did not write pending journal\n'; fail=$((fail + 1))
  failures+=("105b learn-note pending journal missing entry")
fi

# --- 106. learn-note with blank text errors ---
STDERR_CONTAINS="usage: cerebro learn-note" \
run_case 106 "learn-note blank errors" 1 -- "$CEREBRO_BIN" learn-note "   "

# --- 107. learn-set writes the active learnings ---
run_case 107 "learn-set writes active learnings" 0 -- \
  "$CEREBRO_BIN" learn-set "- Keep diffs small; avoid over-engineering."
if [[ -s "$LEARN_ACTIVE" ]] && grep -q "avoid over-engineering" "$LEARN_ACTIVE"; then
  printf 'PASS  107b  learn-set wrote active learnings\n'; pass=$((pass + 1))
else
  printf 'FAIL  107b  learn-set did not write active learnings\n'; fail=$((fail + 1))
  failures+=("107b learn-set active learnings missing")
fi

# --- 108. learnings now shows the active set ---
STDOUT_CONTAINS="avoid over-engineering" \
run_case 108 "learnings shows active set" 0 -- "$CEREBRO_BIN" learnings

# --- 109. learn-set rejects oversized payloads (system-message budget) ---
BIG="$(head -c 1700 < /dev/zero | tr '\0' 'x')"
STDERR_CONTAINS="too large" \
run_case 109 "learn-set oversized rejected" 1 -- "$CEREBRO_BIN" learn-set "$BIG"
# The prior (valid) active learnings must survive a rejected overwrite.
if grep -q "avoid over-engineering" "$LEARN_ACTIVE"; then
  printf 'PASS  109b  rejected learn-set left active learnings intact\n'; pass=$((pass + 1))
else
  printf 'FAIL  109b  rejected learn-set clobbered active learnings\n'; fail=$((fail + 1))
  failures+=("109b oversized learn-set clobbered active learnings")
fi

# --- 110. learn-set with blank text errors ---
STDERR_CONTAINS="usage: cerebro learn-set" \
run_case 110 "learn-set blank errors" 1 -- "$CEREBRO_BIN" learn-set ""

# --- 111. execute: unknown arg still rejected (stacked-branch flags added) ---
STDERR_CONTAINS="unknown arg" \
run_case 111 "execute unknown arg rejected" 1 -- "$CEREBRO_BIN" execute "$REPO" --frob

# --- 112. execute: --base/--branch without a plan or --prompt still errors ---
# Confirms the new flags parse but don't bypass the plan/prompt requirement,
# and fire before any child opencode run is spawned.
STDERR_CONTAINS="requires <plan-path> or --prompt" \
run_case 112 "execute --base/--branch needs plan or prompt" 1 -- \
  "$CEREBRO_BIN" execute "$REPO" --base feat/step-1 --branch feat/step-2

# --- 112b. execute: identical --base and --branch is the removed existing-branch
# invocation -- it must error (the child only ever cuts a FRESH branch, so
# create-X-from-origin/X-and-PR-back-to-X is impossible), not silently enter
# stacked mode. Fires before any child opencode run spawns. ---
STDERR_CONTAINS="--base and --branch must differ" \
run_case 112b "execute identical base/branch errors" 1 -- \
  "$CEREBRO_BIN" execute "$REPO" --prompt "follow-up" --base feat/step-1 --branch feat/step-1

# --- 113. review: --criteria-file missing path fails fast (before the reviewer) ---
STDERR_CONTAINS="cannot read --criteria-file" \
run_case 113 "review --criteria-file missing path" 1 -- \
  "$CEREBRO_BIN" review "$REPO" --criteria-file "$WORKDIR/no-such-plan.md"

# --- 113b. review: --criteria-file empty file also fails fast ---
: > "$WORKDIR/empty-plan.md"
STDERR_CONTAINS="cannot read --criteria-file" \
run_case 113b "review --criteria-file empty file" 1 -- \
  "$CEREBRO_BIN" review "$REPO" --criteria-file "$WORKDIR/empty-plan.md"

# --- 114. review: unknown arg rejected ---
STDERR_CONTAINS="unknown arg" \
run_case 114 "review unknown arg rejected" 1 -- "$CEREBRO_BIN" review "$REPO" --frob

# ========================================================================
# 115-122. Session spec: the requirements of record. `spec set` replaces the
# current spec and archives every version to an append-only history;
# `spec` / `spec history` read them back. These are per-session files that
# survive a context compaction.
# ========================================================================
SPEC_FILE="$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID/spec.md"
SPEC_HIST="$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID/spec-history.jsonl"

# --- 115. spec on a fresh session reports none ---
STDOUT_CONTAINS="no session spec recorded yet" \
run_case 115 "spec empty reports none" 0 -- "$CEREBRO_BIN" spec

# --- 116. spec set records the current spec ---
run_case 116 "spec set records spec" 0 -- \
  "$CEREBRO_BIN" spec set "Build a widget that does X under constraint Y."
if [[ -s "$SPEC_FILE" ]] && grep -q "constraint Y" "$SPEC_FILE"; then
  printf 'PASS  116b  spec set wrote spec.md\n'; pass=$((pass + 1))
else
  printf 'FAIL  116b  spec set did not write spec.md\n'; fail=$((fail + 1))
  failures+=("116b spec set spec.md missing")
fi
if [[ -s "$SPEC_HIST" ]] && grep -q "constraint Y" "$SPEC_HIST"; then
  printf 'PASS  116c  spec set appended to history\n'; pass=$((pass + 1))
else
  printf 'FAIL  116c  spec set did not append to history\n'; fail=$((fail + 1))
  failures+=("116c spec set history missing entry")
fi

# --- 117. spec prints the current spec ---
STDOUT_CONTAINS="constraint Y" \
run_case 117 "spec prints current spec" 0 -- "$CEREBRO_BIN" spec

# --- 118. spec set again overrides current but keeps history ---
run_case 118 "spec set overrides current" 0 -- \
  "$CEREBRO_BIN" spec set "Revised: build a gadget that does Z."
# Current spec is the newest text only...
if grep -q "gadget that does Z" "$SPEC_FILE" && ! grep -q "constraint Y" "$SPEC_FILE"; then
  printf 'PASS  118b  spec.md holds only the latest version\n'; pass=$((pass + 1))
else
  printf 'FAIL  118b  spec.md did not override cleanly\n'; fail=$((fail + 1))
  failures+=("118b spec.md override failed")
fi
# ...but history retains BOTH versions.
hist_lines="$(grep -c '' "$SPEC_HIST" 2>/dev/null || printf 0)"
if [[ "$hist_lines" -eq 2 ]] && grep -q "constraint Y" "$SPEC_HIST" && grep -q "gadget that does Z" "$SPEC_HIST"; then
  printf 'PASS  118c  history retains all versions\n'; pass=$((pass + 1))
else
  printf 'FAIL  118c  history lost a version (lines=%s)\n' "$hist_lines"; fail=$((fail + 1))
  failures+=("118c spec history lost a version")
fi

# --- 119. spec footer reports the history count ---
STDOUT_CONTAINS="2 version(s) recorded" \
run_case 119 "spec reports history count" 0 -- "$CEREBRO_BIN" spec

# --- 120. spec history prints every version oldest first ---
STDOUT_CONTAINS="2 version(s) total" \
run_case 120 "spec history prints all versions" 0 -- "$CEREBRO_BIN" spec history

# --- 121. spec set with blank text errors ---
STDERR_CONTAINS="usage: cerebro spec set" \
run_case 121 "spec set blank errors" 1 -- "$CEREBRO_BIN" spec set "   "

# --- 121b. spec with an unknown action errors ---
STDERR_CONTAINS="usage: cerebro spec" \
run_case 121b "spec unknown action errors" 1 -- "$CEREBRO_BIN" spec frobnicate

# --- 122. status surfaces the recorded spec ---
STDOUT_CONTAINS="session spec: present" \
run_case 122 "status shows session spec" 0 -- "$CEREBRO_BIN" status

# ========================================================================
# 123-124. spec set guard (rule 9 defense-in-depth). Replacing an existing
# non-empty spec prints the current-spec head plus a warning to stderr, but
# never blocks and never alters the record/archive flow. First-ever set is
# silent. Use a fresh session dir so spec state is controlled.
# ========================================================================
GSESS="guard-session"
GDIR="$CEREBRO_HOME/sessions/$GSESS"
mkdir -p "$GDIR"

# --- 123. first-ever spec set emits no replace warning ---
env CEREBRO_SESSION_ID="$GSESS" "$CEREBRO_BIN" spec set "Task A: first task" \
  >/dev/null 2>"$WORKDIR/stderr"
gerr="$(cat "$WORKDIR/stderr")"
if [[ "$gerr" != *"replacing the current session spec"* ]]; then
  printf 'PASS  123  first spec set emits no replace warning\n'; pass=$((pass + 1))
else
  printf 'FAIL  123  first spec set warned unexpectedly\n'; fail=$((fail + 1))
  failures+=("123 first set warned :: $gerr")
fi

# --- 124. replacing an existing spec warns (with current head) on stderr ---
env CEREBRO_SESSION_ID="$GSESS" "$CEREBRO_BIN" spec set "Task B: a different task" \
  >/dev/null 2>"$WORKDIR/stderr"
grc=$?
gerr="$(cat "$WORKDIR/stderr")"
if [[ $grc -eq 0 && "$gerr" == *"replacing the current session spec"* \
      && "$gerr" == *"Task A: first task"* ]]; then
  printf 'PASS  124  spec replace warns with current head\n'; pass=$((pass + 1))
else
  printf 'FAIL  124  spec replace warning missing [rc=%d err=%s]\n' "$grc" "$gerr"; fail=$((fail + 1))
  failures+=("124 replace warn :: rc=$grc")
fi

# --- 124b. the warning is advisory: record + archive still happened ---
if grep -q "Task B: a different task" "$GDIR/spec.md" \
   && [[ "$(grep -c '' "$GDIR/spec-history.jsonl" 2>/dev/null || printf 0)" -eq 2 ]]; then
  printf 'PASS  124b  replace still recorded spec + history\n'; pass=$((pass + 1))
else
  printf 'FAIL  124b  replace did not record cleanly\n'; fail=$((fail + 1))
  failures+=("124b replace record")
fi

# ========================================================================
# 125-128. Child agent session persistence. A stub opencode emits its
# session id; cerebro stores it under child-sessions.json, does not reuse
# completed child sessions, and resumes only entries left in status=running.
# ========================================================================
if (( STUB_OK )); then
  # opencode stub variant: emit a first event carrying the session id, then a
  # successful turn. Honours nothing else (ignores --session).
  ID_STUB_DIR="$WORKDIR/opencode-id-stub"
  mkdir -p "$ID_STUB_DIR"
  cat > "$ID_STUB_DIR/opencode" <<'EOF'
#!/usr/bin/env bash
sid="STUBSESSION-1111"
printf '{"type":"step_start","sessionID":"%s","part":{"type":"step-start"}}\n' "$sid"
printf '{"type":"text","sessionID":"%s","part":{"type":"text","text":"ok"}}\n' "$sid"
printf '{"type":"step_finish","sessionID":"%s","part":{"type":"step-finish","reason":"stop"}}\n' "$sid"
exit 0
EOF
  chmod +x "$ID_STUB_DIR/opencode"
  ID_STUB_PATH="$ID_STUB_DIR:$PATH"

  ESESS="exec-session"; EDIR="$CEREBRO_HOME/sessions/$ESESS"
  mkdir -p "$EDIR/children" "$EDIR/plans"; : > "$EDIR/transcript.jsonl"
  EPLAN1="$EDIR/plans/plan-one.md"
  EPLAN2="$EDIR/plans/plan-two.md"
  printf 'plan one\n' > "$EPLAN1"
  printf 'plan two\n' > "$EPLAN2"

  # --- 125. execute with --branch captures the child session id ---
  env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$ESESS" \
    "$CEREBRO_BIN" execute "$REPO" "$EPLAN1" --branch feat/test \
    >/dev/null 2>&1
  exec_id="$(jq -r '.[].id' "$EDIR/child-sessions.json" 2>/dev/null)"
  if [[ "$exec_id" == "STUBSESSION-1111" ]]; then
    printf 'PASS  125  execute --branch records child session id\n'; pass=$((pass + 1))
  else
    printf 'FAIL  125  execute did not record child id [got=%s]\n' "$exec_id"; fail=$((fail + 1))
    failures+=("125 execute capture :: got=$exec_id")
  fi

  # --- 125b. the first execute logged resume=none (no prior session) ---
  if grep -q 'resume=none' "$EDIR/transcript.jsonl"; then
    printf 'PASS  125b  first execute logged resume=none\n'; pass=$((pass + 1))
  else
    printf 'FAIL  125b  first execute did not log resume=none\n'; fail=$((fail + 1))
    failures+=("125b resume=none missing")
  fi

  # --- 126. a second plan on the same repo+branch does not resume plan one's id ---
  env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$ESESS" \
    "$CEREBRO_BIN" execute "$REPO" "$EPLAN2" --branch feat/test \
    >/dev/null 2>&1
  exec_entries="$(jq 'length' "$EDIR/child-sessions.json" 2>/dev/null)"
  if [[ "$exec_entries" -eq 2 ]] && ! grep -q 'resume=STUBSESSION-1111' "$EDIR/transcript.jsonl"; then
    printf 'PASS  126  same-branch second plan starts its own child session\n'; pass=$((pass + 1))
  else
    printf 'FAIL  126  same-branch plan reused a child [entries=%s transcript=%s]\n' \
      "$exec_entries" "$(cat "$EDIR/transcript.jsonl")"; fail=$((fail + 1))
    failures+=("126 same-branch plan isolation")
  fi

  # --- 126b. re-running a completed execute key also starts fresh. ---
  env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$ESESS" \
    "$CEREBRO_BIN" execute "$REPO" "$EPLAN1" --branch feat/test \
    >/dev/null 2>&1
  if ! grep -q 'resume=STUBSESSION-1111' "$EDIR/transcript.jsonl"; then
    printf 'PASS  126b completed execute child is not auto-resumed\n'; pass=$((pass + 1))
  else
    printf 'FAIL  126b completed execute child was resumed [transcript=%s]\n' \
      "$(cat "$EDIR/transcript.jsonl")"; fail=$((fail + 1))
    failures+=("126b completed execute auto-resume")
  fi

  # --- 126c. distinct --base/--branch drives STACKED-BRANCH MODE; the deleted
  # existing-branch mode wording never appears. ---
  PROMPT_STUB_DIR="$WORKDIR/opencode-prompt-stub"
  mkdir -p "$PROMPT_STUB_DIR"
  cat > "$PROMPT_STUB_DIR/opencode" <<'EOF'
#!/usr/bin/env bash
# The child prompt is the last positional arg under `opencode run`.
printf '%s' "${!#}" > "$PROMPT_CAPTURE"
sid="PROMPTSTUB-1"
printf '{"type":"step_start","sessionID":"%s","part":{"type":"step-start"}}\n' "$sid"
printf '{"type":"text","sessionID":"%s","part":{"type":"text","text":"ok"}}\n' "$sid"
printf '{"type":"step_finish","sessionID":"%s","part":{"type":"step-finish","reason":"stop"}}\n' "$sid"
exit 0
EOF
  chmod +x "$PROMPT_STUB_DIR/opencode"
  PROMPT_STUB_PATH="$PROMPT_STUB_DIR:$PATH"
  PROMPT_CAPTURE="$WORKDIR/stacked-prompt.txt"
  env PATH="$PROMPT_STUB_PATH" CEREBRO_SESSION_ID="$ESESS" \
    PROMPT_CAPTURE="$PROMPT_CAPTURE" \
    "$CEREBRO_BIN" execute "$REPO" --prompt "stack on plan one" \
      --base feat/slug-01 --branch feat/slug-02 >/dev/null 2>&1
  erc=$?
  eprompt="$(cat "$PROMPT_CAPTURE" 2>/dev/null || true)"
  if [[ $erc -eq 0 && "$eprompt" == *"STACKED-BRANCH MODE"* \
        && "$eprompt" == *"create your new branch from origin/feat/slug-01"* \
        && "$eprompt" == *"Name the new branch EXACTLY 'feat/slug-02'"* \
        && "$eprompt" != *"EXISTING-BRANCH MODE"* ]]; then
    printf 'PASS  126c distinct base/branch drives stacked mode (no existing-branch mode)\n'; pass=$((pass + 1))
  else
    printf 'FAIL  126c stacked-mode prompt wrong [rc=%d prompt=%s]\n' \
      "$erc" "$eprompt"; fail=$((fail + 1))
    failures+=("126c stacked-mode prompt :: rc=$erc")
  fi

  # --- 129. stale fallback: a stored id the provider rejects retries fresh
  # (without --resume) and overwrites the store with the new id. ---
  REJECT_STUB_DIR="$WORKDIR/opencode-reject-stub"
  mkdir -p "$REJECT_STUB_DIR"
  cat > "$REJECT_STUB_DIR/opencode" <<'EOF'
#!/usr/bin/env bash
# A resumed run (--session present) is rejected before any event: emit nothing
# so the id-capture stays empty and cerebro retries fresh. A fresh run emits a
# new session id and succeeds.
for a in "$@"; do
  if [[ "$a" == "--session" ]]; then
    exit 0
  fi
done
sid="FRESH-2222"
printf '{"type":"step_start","sessionID":"%s","part":{"type":"step-start"}}\n' "$sid"
printf '{"type":"text","sessionID":"%s","part":{"type":"text","text":"ok"}}\n' "$sid"
printf '{"type":"step_finish","sessionID":"%s","part":{"type":"step-finish","reason":"stop"}}\n' "$sid"
exit 0
EOF
  chmod +x "$REJECT_STUB_DIR/opencode"
  REJECT_STUB_PATH="$REJECT_STUB_DIR:$PATH"

  FSESS="fallback-session"; FDIR="$CEREBRO_HOME/sessions/$FSESS"
  mkdir -p "$FDIR/children"; : > "$FDIR/transcript.jsonl"
  # Seed a bogus-but-fresh running id for the execute key so it is offered
  # for resume. Completed entries are intentionally ignored.
  FKEY="$(printf '%s\0execute\0branch:feat/test|prompt:go' "$REPO" | shasum | cut -d' ' -f1 | cut -c1-16)"
  jq -n --arg k "$FKEY" --arg repo "$REPO" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '{($k): {id:"BOGUS-OLD", provider:"opencode", role:"execute", repo:$repo,
              branch:"feat/test", status:"running", updated_at:$ts}}' \
     > "$FDIR/child-sessions.json"
  env PATH="$REJECT_STUB_PATH" CEREBRO_SESSION_ID="$FSESS" \
    "$CEREBRO_BIN" execute "$REPO" --prompt "go" --branch feat/test >/dev/null 2>&1
  frc=$?
  new_id="$(jq -r --arg k "$FKEY" '.[$k].id' "$FDIR/child-sessions.json" 2>/dev/null)"
  if [[ $frc -eq 0 && "$new_id" == "FRESH-2222" ]] \
     && grep -q '"what":"execute_resume_failed"' "$FDIR/transcript.jsonl"; then
    printf 'PASS  129  rejected resume retries fresh and updates the store\n'; pass=$((pass + 1))
  else
    printf 'FAIL  129  stale fallback failed [rc=%d id=%s]\n' "$frc" "$new_id"; fail=$((fail + 1))
    failures+=("129 stale fallback :: rc=$frc id=$new_id")
  fi

  # --- 130. a resumed execute that DID work (emitted a session init) and then
  # FAILED must NOT be re-run fresh -- re-running would duplicate/partly redo
  # mutating work. The stub starts a session (init -> id captured) on every
  # call and then fails; cerebro must invoke it exactly ONCE, surface the
  # failure, and never log execute_resume_failed. The id is persisted at
  # startup (not on success), so the store now holds the LIVE child's id with
  # status=running -- the half-done work stays resumable on continue. ---
  WORK_COUNT="$WORKDIR/realfail-count"
  WORK_STUB_DIR="$WORKDIR/opencode-realfail-stub"
  mkdir -p "$WORK_STUB_DIR"
  cat > "$WORK_STUB_DIR/opencode" <<EOF
#!/usr/bin/env bash
printf 'x' >> "$WORK_COUNT"
sid="WORKED-9999"
printf '{"type":"step_start","sessionID":"%s","part":{"type":"step-start"}}\n' "\$sid"
printf '{"type":"tool_use","sessionID":"%s","part":{"type":"tool","tool":"bash","callID":"c1","state":{"status":"completed","input":{"command":"git commit"},"output":"done"}}}\n' "\$sid"
printf '{"type":"error","sessionID":"%s","error":{"name":"X","data":{"message":"boom"}}}\n' "\$sid"
exit 0
EOF
  chmod +x "$WORK_STUB_DIR/opencode"
  WORK_STUB_PATH="$WORK_STUB_DIR:$PATH"

  WSESS="realfail-session"; WDIR="$CEREBRO_HOME/sessions/$WSESS"
  mkdir -p "$WDIR/children"; : > "$WDIR/transcript.jsonl"
  # Seed a fresh running stored id so resume is attempted.
  WKEY="$(printf '%s\0execute\0branch:feat/test|prompt:go' "$REPO" | shasum | cut -d' ' -f1 | cut -c1-16)"
  jq -n --arg k "$WKEY" --arg repo "$REPO" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '{($k): {id:"PRIOR-1234", provider:"opencode", role:"execute", repo:$repo,
              branch:"feat/test", status:"running", updated_at:$ts}}' \
     > "$WDIR/child-sessions.json"
  : > "$WORK_COUNT"
  env PATH="$WORK_STUB_PATH" CEREBRO_SESSION_ID="$WSESS" \
    "$CEREBRO_BIN" execute "$REPO" --prompt "go" --branch feat/test >/dev/null 2>&1
  wrc=$?
  invocations="$(wc -c < "$WORK_COUNT" | tr -d ' ')"
  stored_id="$(jq -r --arg k "$WKEY" '.[$k].id' "$WDIR/child-sessions.json" 2>/dev/null)"
  stored_status="$(jq -r --arg k "$WKEY" '.[$k].status' "$WDIR/child-sessions.json" 2>/dev/null)"
  if [[ $wrc -ne 0 && "$invocations" -eq 1 && "$stored_id" == "WORKED-9999" \
        && "$stored_status" == "running" ]] \
     && ! grep -q '"what":"execute_resume_failed"' "$WDIR/transcript.jsonl"; then
    printf 'PASS  130  resumed execute with prior work does not re-run fresh (stays resumable)\n'; pass=$((pass + 1))
  else
    printf 'FAIL  130  resumed real failure re-ran fresh [rc=%d invocations=%s id=%s status=%s]\n' \
      "$wrc" "$invocations" "$stored_id" "$stored_status"; fail=$((fail + 1))
    failures+=("130 mutating resume re-run :: rc=$wrc invocations=$invocations id=$stored_id status=$stored_status")
  fi

  # --- 145. execute runs the child in an isolated worktree: it announces the
  # worktree path, the worktree persists after the run, and the user's MAIN
  # checkout (including a pre-existing uncommitted file) is left untouched. ---
  WTSESS="wt-session"; WTDIR="$CEREBRO_HOME/sessions/$WTSESS"
  mkdir -p "$WTDIR/children"; : > "$WTDIR/transcript.jsonl"
  printf 'precious local work\n' > "$REPO/MY-UNCOMMITTED.txt"
  main_head_before="$(git -C "$REPO" rev-parse HEAD)"
  main_branch_before="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  wtout="$(env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$WTSESS" \
    "$CEREBRO_BIN" execute "$REPO" --prompt "do work in a worktree" 2>/dev/null)"
  wt145="$(printf '%s\n' "$wtout" | sed -n 's/^=== TASK WORKTREE: \(.*\) (branch .*$/\1/p' | head -1)"
  main_head_after="$(git -C "$REPO" rev-parse HEAD)"
  main_branch_after="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  if [[ -n "$wt145" && -d "$wt145" && "$wt145" == "$CEREBRO_HOME/worktrees/"* ]] \
     && git -C "$wt145" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [[ -f "$REPO/MY-UNCOMMITTED.txt" \
           && "$(cat "$REPO/MY-UNCOMMITTED.txt")" == "precious local work" \
           && "$main_head_after" == "$main_head_before" \
           && "$main_branch_after" == "$main_branch_before" ]]; then
    printf 'PASS  145  execute runs in a persistent worktree; main checkout untouched\n'; pass=$((pass + 1))
  else
    printf 'FAIL  145  worktree isolation wrong [wt=%s exists=%d main_uncommitted=%d head=%s/%s]\n' \
      "$wt145" "$([[ -d "$wt145" ]] && echo 1 || echo 0)" \
      "$([[ -f "$REPO/MY-UNCOMMITTED.txt" ]] && echo 1 || echo 0)" \
      "$main_head_before" "$main_head_after"; fail=$((fail + 1))
    failures+=("145 worktree isolation :: wt=$wt145")
  fi
  rm -f "$REPO/MY-UNCOMMITTED.txt"

  # --- 146. a follow-up addressed by the WORKTREE path reuses it: apply-review
  # with <wt> as <repo> commits on that worktree's branch, in that same
  # worktree, and creates NO new worktree. ---
  COMMIT_STUB_DIR="$WORKDIR/opencode-commit-stub"
  mkdir -p "$COMMIT_STUB_DIR"
  cat > "$COMMIT_STUB_DIR/opencode" <<'EOF'
#!/usr/bin/env bash
sid="COMMITSTUB-1"
printf '{"type":"step_start","sessionID":"%s","part":{"type":"step-start"}}\n' "$sid"
printf 'applied by follow-up\n' >> applied.txt
git add applied.txt >/dev/null 2>&1
git commit -q -m "stub follow-up commit" >/dev/null 2>&1
printf '{"type":"text","sessionID":"%s","part":{"type":"text","text":"ok"}}\n' "$sid"
printf '{"type":"step_finish","sessionID":"%s","part":{"type":"step-finish","reason":"stop"}}\n' "$sid"
exit 0
EOF
  chmod +x "$COMMIT_STUB_DIR/opencode"
  COMMIT_STUB_PATH="$COMMIT_STUB_DIR:$PATH"
  FUSESS="followup-session"; FUDIR="$CEREBRO_HOME/sessions/$FUSESS"
  mkdir -p "$FUDIR/children"; : > "$FUDIR/transcript.jsonl"
  WT_FU="$CEREBRO_HOME/worktrees/fu-reuse-test"
  git -C "$REPO" worktree add -q -b feat/fu-reuse "$WT_FU" main >/dev/null 2>&1
  fu_head_before="$(git -C "$WT_FU" rev-parse HEAD)"
  wt_count_before="$(find "$CEREBRO_HOME/worktrees" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  env PATH="$COMMIT_STUB_PATH" CEREBRO_SESSION_ID="$FUSESS" \
    "$CEREBRO_BIN" apply-review "$WT_FU" --prompt "apply the fix" >/dev/null 2>&1
  fu_rc=$?
  fu_head_after="$(git -C "$WT_FU" rev-parse HEAD)"
  fu_branch_after="$(git -C "$WT_FU" rev-parse --abbrev-ref HEAD)"
  wt_count_after="$(find "$CEREBRO_HOME/worktrees" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  if [[ $fu_rc -eq 0 && "$fu_branch_after" == "feat/fu-reuse" \
        && "$fu_head_after" != "$fu_head_before" \
        && -f "$WT_FU/applied.txt" \
        && "$wt_count_before" == "$wt_count_after" ]]; then
    printf 'PASS  146  follow-up addressed by worktree path reuses it (no new worktree)\n'; pass=$((pass + 1))
  else
    printf 'FAIL  146  worktree reuse wrong [rc=%d branch=%s head=%s/%s count=%s/%s]\n' \
      "$fu_rc" "$fu_branch_after" "$fu_head_before" "$fu_head_after" \
      "$wt_count_before" "$wt_count_after"; fail=$((fail + 1))
    failures+=("146 worktree reuse :: rc=$fu_rc branch=$fu_branch_after")
  fi

  # --- 147. `cerebro worktrees cleanup` removes a stale worktree (its branch has
  # no open PR and no unpushed commits) but keeps one with unpushed commits, one
  # whose branch has a (simulated) open PR, and one with uncommitted/untracked
  # work in its tree. A failed PR lookup (gh non-zero) must also KEEP, never read
  # as no-PR. ---
  WT_GC_STALE="$CEREBRO_HOME/worktrees/gc-stale"
  WT_GC_AHEAD="$CEREBRO_HOME/worktrees/gc-ahead"
  WT_GC_PR="$CEREBRO_HOME/worktrees/gc-pr"
  WT_GC_DIRTY="$CEREBRO_HOME/worktrees/gc-dirty"
  WT_GC_PRFAIL="$CEREBRO_HOME/worktrees/gc-prfail"
  git -C "$REPO" worktree add -q -b feat/gc-stale  "$WT_GC_STALE"  main >/dev/null 2>&1
  git -C "$REPO" worktree add -q -b feat/gc-ahead  "$WT_GC_AHEAD"  main >/dev/null 2>&1
  git -C "$REPO" worktree add -q -b feat/gc-pr     "$WT_GC_PR"     main >/dev/null 2>&1
  git -C "$REPO" worktree add -q -b feat/gc-dirty  "$WT_GC_DIRTY"  main >/dev/null 2>&1
  git -C "$REPO" worktree add -q -b feat/gc-prfail "$WT_GC_PRFAIL" main >/dev/null 2>&1
  # gc-ahead carries a commit ahead of the base ref (unpushed) -> must be kept.
  printf 'ahead\n' >> "$WT_GC_AHEAD/a.txt"
  git -C "$WT_GC_AHEAD" add a.txt >/dev/null 2>&1
  git -C "$WT_GC_AHEAD" commit -q -m "unpushed work" >/dev/null 2>&1
  # gc-dirty has only UNCOMMITTED + UNTRACKED work (no commit ahead) -> must be
  # kept by the dirty-tree check, or that work would be destroyed.
  printf 'uncommitted\n' >> "$WT_GC_DIRTY/a.txt"
  printf 'untracked\n' > "$WT_GC_DIRTY/scratch.txt"
  # gh stub: OPEN PR for feat/gc-pr; a forced lookup FAILURE (exit 2) for
  # feat/gc-prfail (transient auth/network) which must KEEP; clean empty (exit 0)
  # for the rest, the only genuine "no open PR".
  GC_GH_DIR="$WORKDIR/gc-gh-stub"; mkdir -p "$GC_GH_DIR"
  cat > "$GC_GH_DIR/gh" <<'EOF'
#!/usr/bin/env bash
br=""; prev=""
for a in "$@"; do [[ "$prev" == "--head" ]] && br="$a"; prev="$a"; done
[[ "$br" == "feat/gc-pr" ]]     && { echo OPEN; exit 0; }
[[ "$br" == "feat/gc-prfail" ]] && exit 2   # lookup failure -> unknown -> keep
exit 0                                        # successful empty -> no open PR
EOF
  chmod +x "$GC_GH_DIR/gh"
  env PATH="$GC_GH_DIR:$PATH" CEREBRO_SESSION_ID="$WTSESS" \
    "$CEREBRO_BIN" worktrees cleanup >/dev/null 2>&1
  if [[ ! -d "$WT_GC_STALE" && -d "$WT_GC_AHEAD" && -d "$WT_GC_PR" \
        && -d "$WT_GC_DIRTY" && -d "$WT_GC_PRFAIL" ]]; then
    printf 'PASS  147  cleanup removes stale, keeps unpushed/open-PR/dirty/PR-lookup-failed\n'; pass=$((pass + 1))
  else
    printf 'FAIL  147  cleanup verdicts wrong [stale=%d ahead=%d pr=%d dirty=%d prfail=%d]\n' \
      "$([[ -d "$WT_GC_STALE" ]] && echo 1 || echo 0)" \
      "$([[ -d "$WT_GC_AHEAD" ]] && echo 1 || echo 0)" \
      "$([[ -d "$WT_GC_PR" ]] && echo 1 || echo 0)" \
      "$([[ -d "$WT_GC_DIRTY" ]] && echo 1 || echo 0)" \
      "$([[ -d "$WT_GC_PRFAIL" ]] && echo 1 || echo 0)"; fail=$((fail + 1))
    failures+=("147 worktrees cleanup verdicts")
  fi
  # Tidy the kept test worktrees so they don't perturb later worktree scans.
  for w in "$WT_FU" "$WT_GC_AHEAD" "$WT_GC_PR" "$WT_GC_DIRTY" "$WT_GC_PRFAIL"; do
    git -C "$REPO" worktree remove --force "$w" >/dev/null 2>&1 || true
  done
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  for b in feat/fu-reuse feat/gc-stale feat/gc-ahead feat/gc-pr feat/gc-dirty feat/gc-prfail; do
    git -C "$REPO" branch -D "$b" >/dev/null 2>&1 || true
  done
else
  printf 'SKIP  125  execute child-session capture (opencode stub unavailable)\n'
  printf 'SKIP  125b execute resume=none log (opencode stub unavailable)\n'
  printf 'SKIP  126  same-branch execute isolation (opencode stub unavailable)\n'
  printf 'SKIP  126b completed execute no-auto-resume (opencode stub unavailable)\n'
  printf 'SKIP  126c distinct base/branch stacked-mode prompt (opencode stub unavailable)\n'
  printf 'SKIP  129  execute stale fallback (opencode stub unavailable)\n'
  printf 'SKIP  130  execute mutating-resume no-rerun (opencode stub unavailable)\n'
  printf 'SKIP  145  execute worktree isolation (opencode stub unavailable)\n'
  printf 'SKIP  146  follow-up worktree reuse (opencode stub unavailable)\n'
  printf 'SKIP  147  worktrees cleanup (opencode stub unavailable)\n'
fi

# opencode reviewer stub: emulate `opencode run` for the read-only reviewer --
# log argv (to assert the agent / review model / flags + the prompt, which is
# now the trailing positional) and emit a run-format event stream whose final
# text is the findings (captured to the findings file). The reviewer runs on the
# independent review model (CEREBRO_REVIEW_MODEL = gpt-5.5), not the implementer
# model (CEREBRO_MODEL = opus).
REVIEW_STUB_DIR="$WORKDIR/opencode-review-stub"
mkdir -p "$REVIEW_STUB_DIR"
REVIEW_ARGV_LOG="$WORKDIR/review-argv.log"
RSID="REVIEWSESS-1"
cat > "$REVIEW_STUB_DIR/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$REVIEW_ARGV_LOG"
sid="$RSID"
printf '{"type":"step_start","sessionID":"%s","part":{"type":"step-start"}}\n' "\$sid"
printf '{"type":"tool_use","sessionID":"%s","part":{"type":"tool","tool":"bash","callID":"c1","state":{"status":"completed","input":{"command":"git diff"},"output":"d"}}}\n' "\$sid"
printf '{"type":"text","sessionID":"%s","part":{"type":"text","text":"## Findings: no issues found"}}\n' "\$sid"
printf '{"type":"step_finish","sessionID":"%s","part":{"type":"step-finish","reason":"stop"}}\n' "\$sid"
exit 0
EOF
chmod +x "$REVIEW_STUB_DIR/opencode"

# --- 127r. the read-only reviewer agent denies edits/writes and is bash-limited
# to inspection commands (this is what makes review genuinely read-only). ---
reviewer_agent="$( ( CEREBRO_LIB_DIR="$here/../lib"; . "$here/../lib/config.sh"; . "$here/../lib/helpers.sh"; . "$here/../lib/payloads.sh"; reviewer_agent_file ) 2>/dev/null )"
if [[ "$reviewer_agent" == *"edit: deny"* && "$reviewer_agent" == *"write: deny"* \
      && "$reviewer_agent" == *"task: deny"* && "$reviewer_agent" == *'"git diff*": allow'* \
      && "$reviewer_agent" == *"READ-ONLY reviewer"* ]]; then
  printf 'PASS  127r  reviewer agent is read-only (edit/write/task denied, git-diff allowed)\n'; pass=$((pass + 1))
else
  printf 'FAIL  127r  reviewer agent not read-only\n'; fail=$((fail + 1))
  failures+=("127r reviewer agent read-only")
fi

if [[ -x "$REVIEW_STUB_DIR/opencode" ]]; then
  REVIEW_STUB_PATH="$REVIEW_STUB_DIR:$PATH"
  RSESS="review-session"; RDIR="$CEREBRO_HOME/sessions/$RSESS"
  mkdir -p "$RDIR/children"; : > "$RDIR/transcript.jsonl"

  # --- 127. review records the opencode session id under a review key ---
  : > "$REVIEW_ARGV_LOG"
  rev_out="$(env PATH="$REVIEW_STUB_PATH" CEREBRO_SESSION_ID="$RSESS" \
    "$CEREBRO_BIN" review "$REPO" 2>/dev/null)"
  rv_id="$(jq -r '.[] | select(.provider=="opencode" and .role=="review") | .id' "$RDIR/child-sessions.json" 2>/dev/null)"
  if [[ "$rv_id" == "$RSID" ]]; then
    printf 'PASS  127  review records the opencode session id under a review key\n'; pass=$((pass + 1))
  else
    printf 'FAIL  127  review did not record the session id [got=%s]\n' "$rv_id"; fail=$((fail + 1))
    failures+=("127 review capture :: got=$rv_id")
  fi

  # --- 127b. the review invokes opencode run on the cerebro-reviewer agent ---
  if grep -q -- '--format json' "$REVIEW_ARGV_LOG" \
      && grep -q -- '--agent cerebro-reviewer' "$REVIEW_ARGV_LOG"; then
    printf 'PASS  127b  review runs opencode --agent cerebro-reviewer --format json\n'; pass=$((pass + 1))
  else
    printf 'FAIL  127b  review missing agent/format [argv=%s]\n' "$(cat "$REVIEW_ARGV_LOG")"; fail=$((fail + 1))
    failures+=("127b review agent/format missing")
  fi

  # --- 127c. review runs on the INDEPENDENT review model (gpt-5.5), never the
  # implementer's opus model -- the whole point of an independent reviewer. ---
  if grep -q -- '--model github-copilot/gpt-5.5' "$REVIEW_ARGV_LOG" \
      && ! grep -q 'claude-opus' "$REVIEW_ARGV_LOG"; then
    printf 'PASS  127c  review runs on the independent gpt-5.5 reviewer model\n'; pass=$((pass + 1))
  else
    printf 'FAIL  127c  review not on gpt-5.5 review model [argv=%s]\n' "$(cat "$REVIEW_ARGV_LOG")"; fail=$((fail + 1))
    failures+=("127c review model missing")
  fi

  # --- 127e. the findings are the run's final message, written to out_path ---
  if [[ -s "$rev_out" ]] && grep -q 'no issues found' "$rev_out"; then
    printf 'PASS  127e  review findings are the run final message (written to out_path)\n'; pass=$((pass + 1))
  else
    printf 'FAIL  127e  review findings not captured [out=%s]\n' "$rev_out"; fail=$((fail + 1))
    failures+=("127e review findings capture :: out=$rev_out")
  fi

  # --- 127d. criteria review still puts the external-tool guidance in the prompt ---
  criteria_plan="$(env CEREBRO_SESSION_ID="$RSESS" \
    "$CEREBRO_BIN" plan $'## Acceptance criteria (checkpoint)\n- Real browser check passes' --out criteria-target 2>/dev/null)"
  : > "$REVIEW_ARGV_LOG"
  env PATH="$REVIEW_STUB_PATH" CEREBRO_SESSION_ID="$RSESS" \
    "$CEREBRO_BIN" review "$REPO" --criteria-file "$criteria_plan" >/dev/null 2>&1
  if grep -q "use verdict EXTERNAL" "$REVIEW_ARGV_LOG" \
      && grep -q "EXTERNAL criteria do not make the final verdict NOT MET" "$REVIEW_ARGV_LOG"; then
    printf 'PASS  127d  criteria prompt externalizes unavailable browser checks\n'; pass=$((pass + 1))
  else
    printf 'FAIL  127d  criteria prompt missing external-tool guidance [argv=%s]\n' "$(cat "$REVIEW_ARGV_LOG")"; fail=$((fail + 1))
    failures+=("127d criteria external guidance missing")
  fi

  # --- 128. a second completed review does not resume the stored review session ---
  : > "$REVIEW_ARGV_LOG"
  env PATH="$REVIEW_STUB_PATH" CEREBRO_SESSION_ID="$RSESS" \
    "$CEREBRO_BIN" review "$REPO" >/dev/null 2>&1
  if ! grep -q -- "--session $RSID" "$REVIEW_ARGV_LOG" \
     && ! grep -q "resume=$RSID" "$RDIR/transcript.jsonl"; then
    printf 'PASS  128  completed review session is not auto-resumed\n'; pass=$((pass + 1))
  else
    printf 'FAIL  128  completed review was resumed [argv=%s]\n' "$(cat "$REVIEW_ARGV_LOG")"; fail=$((fail + 1))
    failures+=("128 review completed auto-resume")
  fi

  # --- 128c. audit runs the reviewer on the plan with plan+context, on the
  # review model, records the session, and echoes the findings path. ---
  audit_plan="$(env CEREBRO_SESSION_ID="$RSESS" \
    "$CEREBRO_BIN" plan "# The plan: touch lib/thing.sh" --out audit-target 2>/dev/null)"
  : > "$REVIEW_ARGV_LOG"
  audit_out="$(env PATH="$REVIEW_STUB_PATH" CEREBRO_SESSION_ID="$RSESS" \
    "$CEREBRO_BIN" audit "$REPO" "$audit_plan" --context "key paths: lib/" 2>/dev/null)"
  audit_argv="$(cat "$REVIEW_ARGV_LOG")"
  audit_id="$(jq -r '.[] | select(.provider=="opencode" and .role=="audit") | .id' "$RDIR/child-sessions.json" 2>/dev/null)"
  if [[ "$audit_out" == "$RDIR/audits/audit-target-audit.md" && -s "$audit_out" \
        && "$audit_argv" == *"--agent cerebro-reviewer"* \
        && "$audit_argv" == *"--model github-copilot/gpt-5.5"* \
        && "$audit_argv" == *"touch lib/thing.sh"* \
        && "$audit_argv" == *"key paths: lib/"* \
        && "$audit_id" == "$RSID" ]]; then
    printf 'PASS  128c  audit runs the reviewer (gpt-5.5) with plan+context, records session\n'; pass=$((pass + 1))
  else
    printf 'FAIL  128c  audit run wrong [out=%s id=%s]\n' "$audit_out" "$audit_id"; fail=$((fail + 1))
    failures+=("128c audit :: out=$audit_out id=$audit_id")
  fi

  # --- 128d. a re-audit of the same completed plan starts a fresh session ---
  : > "$REVIEW_ARGV_LOG"
  env PATH="$REVIEW_STUB_PATH" CEREBRO_SESSION_ID="$RSESS" \
    "$CEREBRO_BIN" audit "$REPO" "$audit_plan" >/dev/null 2>&1
  if ! grep -q -- "--session $RSID" "$REVIEW_ARGV_LOG"; then
    printf 'PASS  128d re-audit does not resume the stored session\n'; pass=$((pass + 1))
  else
    printf 'FAIL  128d re-audit resumed [argv=%s]\n' "$(cat "$REVIEW_ARGV_LOG")"; fail=$((fail + 1))
    failures+=("128d audit resume argv present")
  fi
else
  printf 'SKIP  127  review session capture (opencode stub unavailable)\n'
  printf 'SKIP  127b review agent/format (opencode stub unavailable)\n'
  printf 'SKIP  127c review model (opencode stub unavailable)\n'
  printf 'SKIP  127e review findings (opencode stub unavailable)\n'
  printf 'SKIP  127d review external criteria guidance (opencode stub unavailable)\n'
  printf 'SKIP  128  review completed no-auto-resume (opencode stub unavailable)\n'
  printf 'SKIP  128c audit run (opencode stub unavailable)\n'
  printf 'SKIP  128d audit completed no-auto-resume (opencode stub unavailable)\n'
fi

# ========================================================================
# 131-139. Pair-programming mode (--pair). A paired child runs under a private
# headless `opencode serve`; cerebro POSTs the task to a session on it, streams
# the session's events back into the child log (in run-format), and after each
# turn waits a short window for a one-shot `cerebro steer` over a named pipe. We
# stand up a FAKE `opencode serve` (a tiny HTTP server) so the real pair plumbing
# -- pair_begin, pair_pump, steer, restart, stall -- runs end to end without a
# model. The fake server answers /global/health, POST /session, GET /event (SSE),
# POST .../prompt_async (each prompt -> one assistant turn + session.idle), and
# POST .../abort. A FAKE_STALL_STATE file makes the FIRST server instance freeze
# (emit nothing) so the stall-and-restart path can be exercised; the restart's
# fresh server then completes.
# ========================================================================
FAKE_SERVE_PY="$WORKDIR/fake_opencode_serve.py"
cat > "$FAKE_SERVE_PY" <<'PYEOF'
import json, os, time, queue
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("FAKE_PORT", "0"))
SID = os.environ.get("FAKE_SID", "PAIRSESS-1")
STALL_STATE = os.environ.get("FAKE_STALL_STATE", "")
# When set, the first POST .../prompt_async is answered with a non-2xx status
# (and no events ever follow), modelling opencode serve rejecting the initial
# prompt (e.g. a model-shape mismatch). Exercises the pump's abort-on-reject
# path so we can assert pair_run/execute surface a failure rather than exit 0.
REJECT_PROMPT = bool(os.environ.get("FAKE_REJECT_PROMPT", ""))

turns = queue.Queue()
stall = False
if STALL_STATE and not os.path.exists(STALL_STATE):
    open(STALL_STATE, "w").close()
    stall = True


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/global/health":
            self._send(200, b'{"healthy":true}')
            return
        if self.path == "/event":
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            try:
                while True:
                    try:
                        turns.get(timeout=0.2)
                    except queue.Empty:
                        continue
                    if stall:
                        continue
                    mid = "msg_%d" % int(time.time() * 1000000)
                    evs = [
                        {"type": "message.updated",
                         "properties": {"sessionID": SID, "info": {"id": mid, "role": "assistant"}}},
                        {"type": "message.part.updated",
                         "properties": {"sessionID": SID,
                                        "part": {"type": "text", "text": "child working", "messageID": mid}}},
                        {"type": "session.idle", "properties": {"sessionID": SID}},
                    ]
                    for ev in evs:
                        self.wfile.write(b"data: " + json.dumps(ev).encode() + b"\n\n")
                        self.wfile.flush()
            except Exception:
                return
            return
        self._send(404)

    def do_POST(self):
        ln = int(self.headers.get("content-length", 0) or 0)
        if ln:
            self.rfile.read(ln)
        if self.path == "/session":
            self._send(200, json.dumps({"id": SID}).encode())
            return
        if self.path.endswith("/abort"):
            self._send(204)
            return
        if "/prompt_async" in self.path:
            if REJECT_PROMPT:
                # Reject the prompt and emit nothing: the pump must abort and
                # exit non-zero, surfacing the failure to pair_run/execute.
                self._send(400, b'{"error":"bad model shape"}')
                return
            turns.put(1)
            self._send(204)
            return
        self._send(404)


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF

PAIR_STUB_DIR="$WORKDIR/opencode-pair-stub"
mkdir -p "$PAIR_STUB_DIR"
cat > "$PAIR_STUB_DIR/opencode" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "serve" ]]; then
  port=""; prev=""
  for a in "\$@"; do [[ "\$prev" == "--port" ]] && port="\$a"; prev="\$a"; done
  exec env FAKE_PORT="\$port" python3 "$FAKE_SERVE_PY"
fi
# Non-pair fallback (run): emit one successful turn.
sid="STUBSESS-PAIR"
printf '{"type":"step_start","sessionID":"%s","part":{"type":"step-start"}}\n' "\$sid"
printf '{"type":"text","sessionID":"%s","part":{"type":"text","text":"ok"}}\n' "\$sid"
printf '{"type":"step_finish","sessionID":"%s","part":{"type":"step-finish","reason":"stop"}}\n' "\$sid"
exit 0
EOF
chmod +x "$PAIR_STUB_DIR/opencode"

if [[ -x "$PAIR_STUB_DIR/opencode" ]]; then
  PAIR_STUB_PATH="$PAIR_STUB_DIR:$PATH"
  PSESS="pair-session"; PDIR="$CEREBRO_HOME/sessions/$PSESS"
  mkdir -p "$PDIR/children" "$PDIR/plans"; : > "$PDIR/transcript.jsonl"

  # Background driver: wait for the child's steering pipe to appear, then inject
  # one steering message with `cerebro steer "<msg>"` (auto-discovers the single
  # live child), retrying until it lands in .steering.md. A steer is queued the
  # instant it reaches the live pipe and applied at the next idle window, so we
  # fire as soon as the pipe exists rather than racing a single short window.
  pair_drive() {
    local steerout="$1" f="" sp i j
    for i in $(seq 1 1000); do
      f="$(ls "$PDIR"/children/*.steer.fifo 2>/dev/null | head -1)"
      [[ -n "$f" ]] && break
      sleep 0.05
    done
    [[ -n "$f" ]] || return 0
    sp="${f%.steer.fifo}.steering.md"
    # Keep firing until it lands. A steer to a not-yet-live pipe is a harmless
    # no-op; once the pump is listening the steer queues and is applied at the
    # next idle. Re-checking before each fire bounds duplicates to the apply lag.
    for i in $(seq 1 200); do
      grep -q 'hashmap' "$sp" 2>/dev/null && break
      "$CEREBRO_BIN" steer "actually use a hashmap here" >"$steerout" 2>&1
      sleep 0.3
    done
  }

  # --- 131-133b. execute --pair: live one-shot steer round trip ---
  pair_drive "$WORKDIR/steer.out" &
  STEERER_PID=$!
  pout="$(env PATH="$PAIR_STUB_PATH" CEREBRO_SESSION_ID="$PSESS" CEREBRO_PAIR_IDLE=10 \
    "$CEREBRO_BIN" execute "$REPO" --prompt "do the work" --pair 2>"$WORKDIR/perr")"
  prc=$?
  wait "$STEERER_PID" 2>/dev/null
  perr="$(cat "$WORKDIR/perr")"

  # --- 131. execute --pair runs under serve and produces a child log ---
  if [[ $prc -eq 0 && "$pout" == *".jsonl"* ]]; then
    printf 'PASS  131  execute --pair runs the child under opencode serve\n'; pass=$((pass + 1))
  else
    printf 'FAIL  131  execute --pair did not complete [rc=%d out=%s err=%s]\n' "$prc" "$pout" "$perr"; fail=$((fail + 1))
    failures+=("131 execute --pair :: rc=$prc")
  fi

  # --- 132. execute --pair folds the live steering into a PAIR STEERING block ---
  if [[ "$pout" == *"=== PAIR STEERING"* && "$pout" == *"actually use a hashmap here"* \
        && "$pout" != *"do the work"* ]]; then
    printf 'PASS  132  execute --pair folds back the live steering\n'; pass=$((pass + 1))
  else
    printf 'FAIL  132  execute --pair steering block wrong [out=%s]\n' "$pout"; fail=$((fail + 1))
    failures+=("132 execute --pair steering :: out=$pout")
  fi

  # --- 133. the steering is persisted to a .steering.md beside the child log ---
  clog="$(printf '%s\n' "$pout" | tail -1)"
  spath="${clog%.jsonl}.steering.md"
  if [[ -s "$spath" ]] && grep -q 'actually use a hashmap here' "$spath"; then
    printf 'PASS  133  steering persisted to .steering.md\n'; pass=$((pass + 1))
  else
    printf 'FAIL  133  steering file wrong [path=%s]\n' "$spath"; fail=$((fail + 1))
    failures+=("133 steering file :: path=$spath")
  fi

  # --- 133b. a pair_steering event was logged ---
  if grep -q '"what":"pair_steering"' "$PDIR/transcript.jsonl"; then
    printf 'PASS  133b  pair_steering event logged\n'; pass=$((pass + 1))
  else
    printf 'FAIL  133b  pair_steering event not logged\n'; fail=$((fail + 1))
    failures+=("133b pair_steering event missing")
  fi

  # --- 134. the PAIR MODE banner advertises `cerebro observe <id>` + `cerebro steer` ---
  if [[ "$perr" == *"PAIR MODE"* && "$perr" == *"observe $PSESS"* \
        && "$perr" == *"cerebro steer "* && "$perr" == *".steer.fifo"* \
        && "$perr" != *"cerebro watch"* && "$perr" != *"claude.ai/code"* ]]; then
    printf 'PASS  134  pair banner advertises observe + steer\n'; pass=$((pass + 1))
  else
    printf 'FAIL  134  pair banner wrong [perr=%s]\n' "$perr"; fail=$((fail + 1))
    failures+=("134 pair banner :: perr=$perr")
  fi

  # --- 134c. execute --pair: `cerebro restart` abandons the child + reverts ---
  RESTART_DIAG="wrong approach: rebuilt X instead of extending Y"
  restart_drive() {
    local f="" i j
    for i in $(seq 1 1000); do
      f="$(ls "$PDIR"/children/*.steer.fifo 2>/dev/null | head -1)"
      [[ -n "$f" ]] && break
      sleep 0.05
    done
    [[ -n "$f" ]] || return 0
    for i in $(seq 1 200); do
      [[ -e "${f%.steer.fifo}.restart" ]] && break
      "$CEREBRO_BIN" restart "$f" "$RESTART_DIAG" >/dev/null 2>&1
      sleep 0.3
    done
  }

  restart_drive &
  RESTARTER_PID=$!
  rpout="$(env PATH="$PAIR_STUB_PATH" CEREBRO_SESSION_ID="$PSESS" CEREBRO_PAIR_IDLE=15 \
    "$CEREBRO_BIN" execute "$REPO" --prompt "do the work to restart" --pair 2>"$WORKDIR/rperr")"
  rprc=$?
  wait "$RESTARTER_PID" 2>/dev/null
  if [[ $rprc -eq 0 && "$rpout" == *"=== RESTART REQUESTED ==="* \
        && "$rpout" == *"$RESTART_DIAG"* \
        && "$rpout" == *"=== END RESTART REQUESTED ==="* ]]; then
    printf 'PASS  134c  execute --pair restart reverts + surfaces diagnosis\n'; pass=$((pass + 1))
  else
    printf 'FAIL  134c  execute --pair restart wrong [rc=%d out=%s]\n' \
      "$rprc" "$rpout"; fail=$((fail + 1))
    failures+=("134c execute --pair restart :: rc=$rprc")
  fi

  # --- 134d. after restart the child was reaped: its steer fifo is gone. ---
  rst_fifo="$(ls "$PDIR"/children/*.steer.fifo 2>/dev/null | head -1)"
  if [[ -z "$rst_fifo" ]]; then
    printf 'PASS  134d  restart reaped the child (steer fifo cleaned up)\n'; pass=$((pass + 1))
  else
    printf 'FAIL  134d  restart left a live steer fifo [%s]\n' "$rst_fifo"; fail=$((fail + 1))
    failures+=("134d restart fifo not cleaned :: $rst_fifo")
  fi

  # --- 134e. execute --pair restart tears down the strayed run entirely ---
  STRAY_BR="feat/strayed-fresh-branch"
  GC_CLOSE_LOG="$WORKDIR/restart-gh-close.log"
  GC_CLOSE_DIR="$WORKDIR/restart-gh-stub"; mkdir -p "$GC_CLOSE_DIR"
  cat > "$GC_CLOSE_DIR/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GC_CLOSE_LOG"
exit 0
EOF
  chmod +x "$GC_CLOSE_DIR/gh"
  : > "$GC_CLOSE_LOG"
  printf 'precious main-checkout work\n' > "$REPO/RESTART-PRECIOUS.txt"
  restart_stray_drive() {
    local f="" i j wt
    for i in $(seq 1 1000); do
      f="$(ls "$PDIR"/children/*.steer.fifo 2>/dev/null | head -1)"
      [[ -n "$f" ]] && break
      sleep 0.05
    done
    [[ -n "$f" ]] || return 0
    ls -1 "$CEREBRO_HOME/worktrees" 2>/dev/null | sort > "$WORKDIR/wt-after"
    wt="$CEREBRO_HOME/worktrees/$(comm -13 "$WORKDIR/wt-before" "$WORKDIR/wt-after" | head -1)"
    printf '%s' "$wt" > "$WORKDIR/stray-wt"
    git -C "$wt" checkout -q -b "$STRAY_BR" 2>/dev/null
    printf 'strayed branch work\n' >> "$wt/a.txt"
    git -C "$wt" add a.txt 2>/dev/null
    git -C "$wt" commit -q -m "strayed work" 2>/dev/null
    for i in $(seq 1 200); do
      [[ -e "${f%.steer.fifo}.restart" ]] && break
      "$CEREBRO_BIN" restart "$f" "strayed onto a fresh branch" >/dev/null 2>&1
      sleep 0.3
    done
  }

  ls -1 "$CEREBRO_HOME/worktrees" 2>/dev/null | sort > "$WORKDIR/wt-before"
  restart_stray_drive &
  STRAY_PID=$!
  env PATH="$GC_CLOSE_DIR:$PAIR_STUB_PATH" CEREBRO_SESSION_ID="$PSESS" CEREBRO_PAIR_IDLE=15 \
    "$CEREBRO_BIN" execute "$REPO" --prompt "do the work then stray off-branch" --pair \
    >/dev/null 2>&1
  wait "$STRAY_PID" 2>/dev/null
  stray_wt="$(cat "$WORKDIR/stray-wt" 2>/dev/null || true)"
  stray_branch_gone=0
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$STRAY_BR" || stray_branch_gone=1
  stray_wt_gone=0
  [[ -n "$stray_wt" && ! -d "$stray_wt" ]] && stray_wt_gone=1
  stray_main_ok=0
  [[ -f "$REPO/RESTART-PRECIOUS.txt" \
     && "$(cat "$REPO/RESTART-PRECIOUS.txt")" == "precious main-checkout work" ]] && stray_main_ok=1
  stray_remote_attempted=0
  grep -q "pr close $STRAY_BR --delete-branch" "$GC_CLOSE_LOG" 2>/dev/null && stray_remote_attempted=1
  if [[ $stray_branch_gone -eq 1 && $stray_wt_gone -eq 1 && $stray_main_ok -eq 1 \
        && $stray_remote_attempted -eq 1 ]]; then
    printf 'PASS  134e  execute --pair restart tears down fresh branch + PR + worktree; main intact\n'; pass=$((pass + 1))
  else
    printf 'FAIL  134e  restart teardown wrong [branch_gone=%d wt_gone=%d main_ok=%d remote=%d wt=%s]\n' \
      "$stray_branch_gone" "$stray_wt_gone" "$stray_main_ok" "$stray_remote_attempted" "$stray_wt"; fail=$((fail + 1))
    failures+=("134e restart teardown :: branch_gone=$stray_branch_gone wt_gone=$stray_wt_gone main_ok=$stray_main_ok")
  fi
  git -C "$REPO" branch -D "$STRAY_BR" >/dev/null 2>&1 || true
  rm -f "$REPO/RESTART-PRECIOUS.txt"

  # --- 135. WITHOUT --pair, no serve / banner: the run goes through `opencode run`. ---
  env PATH="$PAIR_STUB_PATH" CEREBRO_SESSION_ID="$PSESS" \
    "$CEREBRO_BIN" execute "$REPO" --prompt "no pairing" >/dev/null 2>"$WORKDIR/nperr"
  nprc=$?
  npperr="$(cat "$WORKDIR/nperr")"
  if [[ $nprc -eq 0 && "$npperr" != *"PAIR MODE"* ]]; then
    printf 'PASS  135  default execute stays clean (no pair banner)\n'; pass=$((pass + 1))
  else
    printf 'FAIL  135  default execute leaked pair mode [rc=%d err=%s]\n' "$nprc" "$npperr"; fail=$((fail + 1))
    failures+=("135 default execute pair leak :: rc=$nprc")
  fi

  # --- 136. audit has no pair mode (read-only reviewer has no live-steer) ---
  pair_plan="$(env CEREBRO_SESSION_ID="$PSESS" \
    "$CEREBRO_BIN" plan "# Add a cache" --out pair-plan 2>/dev/null)"
  qerr="$(env CEREBRO_SESSION_ID="$PSESS" \
    "$CEREBRO_BIN" audit "$REPO" "$pair_plan" --pair 2>&1 >/dev/null)"
  qrc=$?
  if [[ $qrc -ne 0 && "$qerr" == *"unknown arg: --pair"* ]]; then
    printf 'PASS  136  audit rejects --pair (read-only reviewer has no live-steer)\n'; pass=$((pass + 1))
  else
    printf 'FAIL  136  audit --pair not rejected [rc=%d err=%s]\n' "$qrc" "$qerr"; fail=$((fail + 1))
    failures+=("136 audit --pair rejection :: rc=$qrc")
  fi

  # --- 137. apply-review --prompt --pair pairs on the current branch ---
  apout="$(env PATH="$PAIR_STUB_PATH" CEREBRO_SESSION_ID="$PSESS" CEREBRO_PAIR_IDLE=2 \
    "$CEREBRO_BIN" apply-review "$REPO" --prompt "tidy up" --pair 2>"$WORKDIR/aperr")"
  arc=$?
  if [[ $arc -eq 0 && "$apout" == *".jsonl"* && "$(cat "$WORKDIR/aperr")" == *"PAIR MODE"* ]]; then
    printf 'PASS  137  apply-review --pair runs the child under opencode serve\n'; pass=$((pass + 1))
  else
    printf 'FAIL  137  apply-review --pair wrong [rc=%d out=%s]\n' "$arc" "$apout"; fail=$((fail + 1))
    failures+=("137 apply-review --pair :: rc=$arc")
  fi

  # --- 138. cerebro observe: from an OBSERVER session, tail a TARGET session's
  # live paired children. Stand up a fake live paired child (a run-format log + a
  # steer pipe held open by a reader) under a target session, then run the real
  # `cerebro observe <target>` from a separate observer session and assert it
  # reports the child label, its message, the edit (with content preview), and an
  # active STATUS that names the live child. ---
  WTGT="$CEREBRO_HOME/sessions/observe-target/children"; mkdir -p "$WTGT"
  mkdir -p "$CEREBRO_HOME/sessions/observe-watcher"
  wfifo="$WTGT/execute-demo.steer.fifo"; wlog="$WTGT/execute-demo.jsonl"
  mkfifo "$wfifo"
  python3 -c 'import os,sys,time; os.open(sys.argv[1], os.O_RDONLY|os.O_NONBLOCK); time.sleep(6)' "$wfifo" &
  WHOLDER=$!; disown "$WHOLDER" 2>/dev/null || true
  {
    printf '%s\n' '{"type":"text","sessionID":"OBS-1","part":{"type":"text","text":"Introducing a Cache abstraction"}}'
    printf '%s\n' '{"type":"tool_use","sessionID":"OBS-1","part":{"type":"tool","tool":"write","state":{"input":{"filePath":"src/cache.ts","content":"export interface Cache {}"}}}}'
    printf '%s\n' '{"type":"step_finish","sessionID":"OBS-1","part":{"type":"step-finish","reason":"stop"}}'
  } > "$wlog"
  obsout="$(CEREBRO_SESSION_ID=observe-watcher CEREBRO_OBSERVE_WINDOW=3 CEREBRO_OBSERVE_QUIET=1 \
    "$CEREBRO_BIN" observe observe-target 2>/dev/null)"
  kill "$WHOLDER" 2>/dev/null; rm -f "$wfifo"
  if [[ "$obsout" == *"execute-demo"* && "$obsout" == *"Introducing a Cache abstraction"* \
        && "$obsout" == *"write src/cache.ts :: export interface Cache {}"* \
        && "$obsout" == *"OBSERVE STATUS: active"* && "$obsout" == *"live: execute-demo"* ]]; then
    printf 'PASS  138  cerebro observe tails a target session live paired child\n'; pass=$((pass + 1))
  else
    printf 'FAIL  138  observe wrong [out=%s]\n' "$obsout"; fail=$((fail + 1))
    failures+=("138 observe :: out=$obsout")
  fi

  # --- 138b. cerebro observe reports done once the child's pipe closes. ---
  obsdone="$(CEREBRO_SESSION_ID=observe-watcher CEREBRO_OBSERVE_WINDOW=2 CEREBRO_OBSERVE_QUIET=1 \
    "$CEREBRO_BIN" observe observe-target 2>/dev/null)"
  if [[ "$obsdone" == *"OBSERVE STATUS: done"* ]]; then
    printf 'PASS  138b  cerebro observe reports done when no live children remain\n'; pass=$((pass + 1))
  else
    printf 'FAIL  138b  observe done wrong [out=%s]\n' "$obsdone"; fail=$((fail + 1))
    failures+=("138b observe done :: out=$obsdone")
  fi

  # --- 138c. observe renders todowrite as a `plan:` line and carries a full
  # function body past the old clip, so the observer can narrate the roadmap and
  # quote the actual design. ---
  WTGT2="$CEREBRO_HOME/sessions/observe-target2/children"; mkdir -p "$WTGT2"
  mkdir -p "$CEREBRO_HOME/sessions/observe-watcher2"
  wfifo2="$WTGT2/execute-deep.steer.fifo"; wlog2="$WTGT2/execute-deep.jsonl"
  mkfifo "$wfifo2"
  python3 -c 'import os,sys,time; os.open(sys.argv[1], os.O_RDONLY|os.O_NONBLOCK); time.sleep(6)' "$wfifo2" &
  WHOLDER2=$!; disown "$WHOLDER2" 2>/dev/null || true
  longbody="$(python3 -c 'print("export function step(s){" + "/*x*/"*200 + "return s;}", end="")')"
  {
    printf '%s\n' '{"type":"tool_use","sessionID":"OBS-2","part":{"type":"tool","tool":"todowrite","state":{"input":{"todos":[{"content":"ring rules engine","status":"completed"},{"content":"wire controller","status":"in_progress"}]}}}}'
    printf '{"type":"tool_use","sessionID":"OBS-2","part":{"type":"tool","tool":"write","state":{"input":{"filePath":"rules.js","content":%s}}}}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$longbody")"
    printf '%s\n' '{"type":"step_finish","sessionID":"OBS-2","part":{"type":"step-finish","reason":"stop"}}'
  } > "$wlog2"
  obsdeep="$(CEREBRO_SESSION_ID=observe-watcher2 CEREBRO_OBSERVE_WINDOW=3 CEREBRO_OBSERVE_QUIET=1 \
    "$CEREBRO_BIN" observe observe-target2 2>/dev/null)"
  kill "$WHOLDER2" 2>/dev/null; rm -f "$wfifo2"
  if [[ "$obsdeep" == *"plan: [x] ring rules engine | [>] wire controller"* \
        && "$obsdeep" == *"return s;}"* ]]; then
    printf 'PASS  138c  observe renders the plan and a full function body\n'; pass=$((pass + 1))
  else
    printf 'FAIL  138c  observe deep wrong [out=%s]\n' "$obsdeep"; fail=$((fail + 1))
    failures+=("138c observe deep :: out=$obsdeep")
  fi

  # --- 138d. cerebro --observe launches a watch-and-steer-only session: it execs
  # `opencode --agent cerebro-observer --prompt "<kickoff>"`, and the generated
  # observer agent file carries the OBSERVE MODE overlay plus a bash permission
  # block narrowed to observe/steer (no broad cerebro, no edit/write). The stub
  # opencode just logs argv and exits. ---
  OBS_STUB_DIR="$WORKDIR/observe-launch-stub"; mkdir -p "$OBS_STUB_DIR"
  OBS_ARGV_LOG="$WORKDIR/observe-launch-argv.log"; : > "$OBS_ARGV_LOG"
  cat > "$OBS_STUB_DIR/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$OBS_ARGV_LOG"
exit 0
EOF
  chmod +x "$OBS_STUB_DIR/opencode"
  OBSD_FIFO="$CEREBRO_HOME/sessions/observe-target2/children/execute-live.steer.fifo"
  mkfifo "$OBSD_FIFO"
  python3 -c 'import os,sys,time; os.open(sys.argv[1], os.O_RDONLY|os.O_NONBLOCK); time.sleep(8)' "$OBSD_FIFO" &
  OBSD_HOLDER=$!; disown "$OBSD_HOLDER" 2>/dev/null || true
  sleep 0.3
  ( PATH="$OBS_STUB_DIR:$PATH" CEREBRO_SESSION_ID=observe-launcher \
      "$CEREBRO_BIN" --observe observe-target2 >/dev/null 2>&1 )
  kill "$OBSD_HOLDER" 2>/dev/null; rm -f "$OBSD_FIFO"
  obslaunch="$(cat "$OBS_ARGV_LOG")"
  obsagent="$(cat "$CEREBRO_HOME/.opencode/agent/cerebro-observer.md" 2>/dev/null)"
  if [[ "$obslaunch" == *"--agent cerebro-observer"* \
        && "$obslaunch" == *"--prompt"* \
        && "$obslaunch" == *"Start observing session observe-target2 now"* \
        && "$obsagent" == *"OBSERVE MODE"* \
        && "$obsagent" == *"cerebro observe"* \
        && "$obsagent" != *"cerebro:"* ]]; then
    printf 'PASS  138d  cerebro --observe launches a watch-and-steer-only session\n'; pass=$((pass + 1))
  else
    printf 'FAIL  138d  observe launch wrong [argv=%s]\n' "$obslaunch"; fail=$((fail + 1))
    failures+=("138d observe launch :: argv=$obslaunch")
  fi

  # --- 138e. cerebro --observe blocks until something is observable: with no
  # live paired children it must NOT exec opencode yet; once a target sprouts a
  # live child it proceeds and launches. ---
  mkdir -p "$CEREBRO_HOME/sessions/observe-wait-target/children"
  OBSE_ARGV_LOG="$WORKDIR/observe-wait-argv.log"; : > "$OBSE_ARGV_LOG"
  OBSE_STUB_DIR="$WORKDIR/observe-wait-stub"; mkdir -p "$OBSE_STUB_DIR"
  cat > "$OBSE_STUB_DIR/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "launched" >> "$OBSE_ARGV_LOG"
exit 0
EOF
  chmod +x "$OBSE_STUB_DIR/opencode"
  ( PATH="$OBSE_STUB_DIR:$PATH" CEREBRO_SESSION_ID=observe-wait-launcher \
      CEREBRO_OBSERVE_POLL=0.3 \
      "$CEREBRO_BIN" --observe observe-wait-target >/dev/null 2>&1 ) &
  OBSE_LAUNCH=$!
  sleep 1
  obse_early="$(cat "$OBSE_ARGV_LOG")"
  OBSE_FIFO="$CEREBRO_HOME/sessions/observe-wait-target/children/execute-go.steer.fifo"
  mkfifo "$OBSE_FIFO"
  python3 -c 'import os,sys,time; os.open(sys.argv[1], os.O_RDONLY|os.O_NONBLOCK); time.sleep(6)' "$OBSE_FIFO" &
  OBSE_HOLDER=$!; disown "$OBSE_HOLDER" 2>/dev/null || true
  obse_late=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    obse_late="$(cat "$OBSE_ARGV_LOG")"
    [[ -n "$obse_late" ]] && break
  done
  kill "$OBSE_HOLDER" 2>/dev/null; wait "$OBSE_LAUNCH" 2>/dev/null; rm -f "$OBSE_FIFO"
  if [[ -z "$obse_early" && "$obse_late" == *"launched"* ]]; then
    printf 'PASS  138e  cerebro --observe waits for observable, then launches\n'; pass=$((pass + 1))
  else
    printf 'FAIL  138e  observe wait wrong [early=%s late=%s]\n' "$obse_early" "$obse_late"; fail=$((fail + 1))
    failures+=("138e observe wait :: early=$obse_early late=$obse_late")
  fi

  # --- 139. a frozen paired child is reaped and relaunched (stall -> restart).
  # The FIRST fake server instance freezes (emits nothing); the pump reaps it and
  # marks the child stalled; cerebro restarts it, and the fresh server completes. ---
  STALL_STATE="$WORKDIR/pair-stall-once.state"
  rm -f "$STALL_STATE"
  rstout="$(env PATH="$PAIR_STUB_PATH" CEREBRO_SESSION_ID="$PSESS" \
    FAKE_STALL_STATE="$STALL_STATE" \
    CEREBRO_PAIR_IDLE=1 CEREBRO_PAIR_STALL=1 CEREBRO_PAIR_STALL_BUSY=1 \
    CEREBRO_PAIR_STALL_RETRIES=1 CEREBRO_PAIR_STALL_BACKOFF=0 \
    "$CEREBRO_BIN" execute "$REPO" --prompt "stall once then resume" --pair 2>"$WORKDIR/rsterr")"
  rstrc=$?
  if [[ $rstrc -eq 0 && "$rstout" == *".jsonl"* ]] \
        && grep -q '"what":"pair_stall_restart"' "$PDIR/transcript.jsonl"; then
    printf 'PASS  139  paired stall reaps and restarts the child\n'; pass=$((pass + 1))
  else
    printf 'FAIL  139  paired stall did not restart [rc=%d out=%s err=%s]\n' \
      "$rstrc" "$rstout" "$(cat "$WORKDIR/rsterr")"; fail=$((fail + 1))
    failures+=("139 pair stall restart :: rc=$rstrc")
  fi

  # --- 139b. a REJECTED initial prompt (serve answers /prompt_async non-2xx and
  # emits no events) must surface as a FAILURE, not exit 0. The pump aborts with
  # a non-zero exit; pair_run must propagate that (it sits at PIPESTATUS[1], the
  # pump -- not [2], tee, which would mask it). Regression for pair_run returning
  # tee's status: execute must die (rc != 0) and log execute_failed, and the
  # rejected-prompt diagnostic must land in the .pump.log sidecar. ---
  RJSESS="pair-reject-session"; RJDIR="$CEREBRO_HOME/sessions/$RJSESS"
  mkdir -p "$RJDIR/children" "$RJDIR/plans"; : > "$RJDIR/transcript.jsonl"
  rjout="$(env PATH="$PAIR_STUB_PATH" CEREBRO_SESSION_ID="$RJSESS" \
    FAKE_REJECT_PROMPT=1 CEREBRO_PAIR_IDLE=1 \
    "$CEREBRO_BIN" execute "$REPO" --prompt "prompt that gets rejected" --pair \
    >"$WORKDIR/rjout" 2>"$WORKDIR/rjerr")"
  rjrc=$?
  rjerr="$(cat "$WORKDIR/rjerr")"
  # The child log path is the worktree's child log; find the matching .pump.log.
  rjpump="$(ls "$RJDIR"/children/*.pump.log 2>/dev/null | head -1)"
  rjpumptxt="$(cat "$rjpump" 2>/dev/null || true)"
  if [[ $rjrc -ne 0 ]] \
     && grep -q '"what":"execute_failed"' "$RJDIR/transcript.jsonl" \
     && ! grep -q '"what":"execute_finished"' "$RJDIR/transcript.jsonl" \
     && [[ "$rjpumptxt" == *"not accepted by opencode serve"* ]]; then
    printf 'PASS  139b  rejected initial prompt surfaces a failure (not exit 0)\n'; pass=$((pass + 1))
  else
    printf 'FAIL  139b  rejected prompt did not surface failure [rc=%d err=%s pump=%s]\n' \
      "$rjrc" "$rjerr" "$rjpumptxt"; fail=$((fail + 1))
    failures+=("139b rejected prompt :: rc=$rjrc")
  fi
else
  for t in 131 132 133 133b 134 134c 134d 134e 135 136 137 138 138b 138c 138d 138e 139 139b; do
    printf 'SKIP  %s  pair-mode (opencode stub unavailable)\n' "$t"
  done
fi

# ========================================================================
# 140-143. Resume-on-continue for in-flight children. A child's resumable id
# is persisted the instant it starts (not on success), entries carry a
# running/done status, and `cerebro status` surfaces still-running (=
# interrupted) children so the orchestrator can resume them on continue.
# ========================================================================

# --- 141. cerebro status surfaces a still-running (interrupted) child with a
# resume hint. No stub needed: we seed a fresh running entry directly. ---
SSESS="status-inflight-session"; SDIR="$CEREBRO_HOME/sessions/$SSESS"
mkdir -p "$SDIR/children"; : > "$SDIR/transcript.jsonl"
jq -n --arg k deadbeefdeadbeef --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   --arg repo "$REPO" \
   '{($k): {id:"INFLIGHT-1", provider:"opencode", role:"execute", repo:$repo,
            branch:"feat/wip", log:"/tmp/x.jsonl", status:"running",
            started_at:$ts, updated_at:$ts}}' \
   > "$SDIR/child-sessions.json"
sout="$(env CEREBRO_SESSION_ID="$SSESS" "$CEREBRO_BIN" status 2>/dev/null)"
if grep -q 'interrupted / in-flight children' <<<"$sout" \
   && grep -q 'feat/wip' <<<"$sout" \
   && grep -q 'resume:' <<<"$sout"; then
  printf 'PASS  141  status lists interrupted in-flight children with a resume hint\n'; pass=$((pass + 1))
else
  printf 'FAIL  141  status missing in-flight section [out=%s]\n' "$sout"; fail=$((fail + 1))
  failures+=("141 status in-flight :: out=$sout")
fi

# --- 142. a stale (over-TTL) running entry is NOT listed as in-flight. ---
jq -n --arg k cafecafecafecafe \
   '{($k): {id:"OLD-1", provider:"opencode", role:"execute", repo:"/r",
            branch:"feat/old", log:"/tmp/o.jsonl", status:"running",
            started_at:"2000-01-01T00:00:00Z", updated_at:"2000-01-01T00:00:00Z"}}' \
   > "$SDIR/child-sessions.json"
sout2="$(env CEREBRO_SESSION_ID="$SSESS" "$CEREBRO_BIN" status 2>/dev/null)"
if ! grep -q 'feat/old' <<<"$sout2"; then
  printf 'PASS  142  status omits stale (over-TTL) in-flight children\n'; pass=$((pass + 1))
else
  printf 'FAIL  142  status listed a stale in-flight child [out=%s]\n' "$sout2"; fail=$((fail + 1))
  failures+=("142 stale in-flight listed")
fi

if (( STUB_OK )); then
  # --- 140. a successful execute marks its child status=done (so it does NOT
  # show up as interrupted), and the id is recorded. ---
  DSESS="done-status-session"; DDIR="$CEREBRO_HOME/sessions/$DSESS"
  mkdir -p "$DDIR/children"; : > "$DDIR/transcript.jsonl"
  env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$DSESS" \
    "$CEREBRO_BIN" execute "$REPO" --prompt "do it" --branch feat/done >/dev/null 2>&1
  dstatus="$(jq -r '.[].status' "$DDIR/child-sessions.json" 2>/dev/null)"
  dlist="$(env CEREBRO_SESSION_ID="$DSESS" "$CEREBRO_BIN" status 2>/dev/null \
           | sed -n '/in-flight children/,/last review/p')"
  if [[ "$dstatus" == "done" ]] && ! grep -q 'feat/done' <<<"$dlist"; then
    printf 'PASS  140  successful execute marks status=done (off the in-flight list)\n'; pass=$((pass + 1))
  else
    printf 'FAIL  140  execute did not mark done [status=%s list=%s]\n' "$dstatus" "$dlist"; fail=$((fail + 1))
    failures+=("140 done status :: status=$dstatus")
  fi

  # --- 143. apply-review does not auto-resume a completed same-branch child. ---
  ARSESS="apply-resume-session"; ARDIR="$CEREBRO_HOME/sessions/$ARSESS"
  mkdir -p "$ARDIR/children"; : > "$ARDIR/transcript.jsonl"
  env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$ARSESS" \
    "$CEREBRO_BIN" apply-review "$REPO" --prompt "first fix" >/dev/null 2>&1
  env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$ARSESS" \
    "$CEREBRO_BIN" apply-review "$REPO" --prompt "second fix" >/dev/null 2>&1
  if ! grep -q 'resume=STUBSESSION-1111' "$ARDIR/transcript.jsonl"; then
    printf 'PASS  143  completed apply-review child is not auto-resumed\n'; pass=$((pass + 1))
  else
    printf 'FAIL  143  apply-review resumed a completed child [transcript=%s]\n' "$(cat "$ARDIR/transcript.jsonl")"; fail=$((fail + 1))
    failures+=("143 apply-review completed auto-resume")
  fi

  # --- 144. doc-write likewise starts fresh after a completed same-branch child. ---
  DWSESS="doc-resume-session"; DWDIR="$CEREBRO_HOME/sessions/$DWSESS"
  mkdir -p "$DWDIR/children"; : > "$DWDIR/transcript.jsonl"
  env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$DWSESS" \
    "$CEREBRO_BIN" doc-write "$REPO" --prompt "doc pass one" >/dev/null 2>&1
  env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$DWSESS" \
    "$CEREBRO_BIN" doc-write "$REPO" --prompt "doc pass two" >/dev/null 2>&1
  if ! grep -q 'resume=STUBSESSION-1111' "$DWDIR/transcript.jsonl"; then
    printf 'PASS  144  completed doc-write child is not auto-resumed\n'; pass=$((pass + 1))
  else
    printf 'FAIL  144  doc-write resumed a completed child [transcript=%s]\n' "$(cat "$DWDIR/transcript.jsonl")"; fail=$((fail + 1))
    failures+=("144 doc-write completed auto-resume")
  fi
else
  for t in 140 143 144; do
    printf 'SKIP  %s  child resume-on-continue (opencode stub unavailable)\n' "$t"
  done
fi

# ========================================================================
# 150-156. `cerebro answer` -- resume a paused child with an answer.
# Validation/resolution paths fire before any opencode invocation; the
# stub-backed cases verify the resume actually happens.
# ========================================================================

# --- 150. validation: empty answer ---
STDERR_CONTAINS="empty answer" \
run_case 150 "answer empty-answer rejected" 1 -- "$CEREBRO_BIN" answer CHILD-123

# --- 151. validation: old selector flags are no longer accepted ---
STDERR_CONTAINS="unknown arg" \
run_case 151 "answer selector flags rejected" 1 -- "$CEREBRO_BIN" answer CHILD-123 "go" --role bogus

# --- 152. validation: missing child id ---
STDERR_CONTAINS="usage" \
run_case 152 "answer missing child id rejected" 1 -- "$CEREBRO_BIN" answer

# --- 153. no stored child session with that id in the current parent session ---
STDERR_CONTAINS="no fresh child session" \
run_case 153 "answer unknown child session" 1 -- "$CEREBRO_BIN" answer NO-SUCH-CHILD "go"

if (( STUB_OK )); then
  # --- 154. answer resolves the child session id and resumes it ---
  ANSESS="answer-session"; ANDIR="$CEREBRO_HOME/sessions/$ANSESS"
  mkdir -p "$ANDIR/children" "$ANDIR/plans"; : > "$ANDIR/transcript.jsonl"
  # Seed a stored execute session for this repo.
  env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$ANSESS" \
    "$CEREBRO_BIN" execute "$REPO" --prompt "do the thing" --branch feat/ans >/dev/null 2>&1
  ans_out="$(env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$ANSESS" \
    "$CEREBRO_BIN" answer STUBSESSION-1111 "use option B" 2>/dev/null)"
  if grep -q '"what":"answer_started"' "$ANDIR/transcript.jsonl" \
     && grep -q 'resume=STUBSESSION-1111' "$ANDIR/transcript.jsonl"; then
    printf 'PASS  154  answer resumes the stored execute session\n'; pass=$((pass + 1))
  else
    printf 'FAIL  154  answer did not resume [transcript=%s]\n' "$(cat "$ANDIR/transcript.jsonl")"; fail=$((fail + 1))
    failures+=("154 answer resume")
  fi

  # --- 155. answer surfaces the child's closing message and child id on stdout ---
  if [[ "$ans_out" == *"child closing message"* && "$ans_out" == *"child session: STUBSESSION-1111"* \
        && "$ans_out" == *"ok"* ]]; then
    printf 'PASS  155  answer surfaces the child closing message\n'; pass=$((pass + 1))
  else
    printf 'FAIL  155  answer did not surface closing message [out=%s]\n' "$ans_out"; fail=$((fail + 1))
    failures+=("155 answer surface :: out=$ans_out")
  fi

  # --- 155b. answer targets the exact child session id when several plans
  # share one branch. ---
  AXSESS="answer-exact-session"; AXDIR="$CEREBRO_HOME/sessions/$AXSESS"
  mkdir -p "$AXDIR/children" "$AXDIR/plans"; : > "$AXDIR/transcript.jsonl"
  AXP1="$AXDIR/plans/one.md"; AXP2="$AXDIR/plans/two.md"
  printf 'one\n' > "$AXP1"; printf 'two\n' > "$AXP2"
  AXK1="$(printf '%s\0execute\0branch:feat/ans|plan:%s' "$REPO" "$AXP1" | shasum | cut -d' ' -f1 | cut -c1-16)"
  AXK2="$(printf '%s\0execute\0branch:feat/ans|plan:%s' "$REPO" "$AXP2" | shasum | cut -d' ' -f1 | cut -c1-16)"
  jq -n --arg k1 "$AXK1" --arg k2 "$AXK2" --arg repo "$REPO" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{($k1): {id:"CHILD-ONE", provider:"opencode", role:"execute", repo:$repo,
                  branch:"feat/ans", status:"done", updated_at:$ts},
          ($k2): {id:"CHILD-TWO", provider:"opencode", role:"execute", repo:$repo,
                  branch:"feat/ans", status:"done", updated_at:$ts}}' \
        > "$AXDIR/child-sessions.json"
  env PATH="$ID_STUB_PATH" CEREBRO_SESSION_ID="$AXSESS" \
    "$CEREBRO_BIN" answer CHILD-TWO "use option B" >/dev/null 2>&1
  if grep -q 'resume=CHILD-TWO' "$AXDIR/transcript.jsonl" \
     && ! grep -q 'resume=CHILD-ONE' "$AXDIR/transcript.jsonl"; then
    printf 'PASS  155b answer targets exact same-branch plan child\n'; pass=$((pass + 1))
  else
    printf 'FAIL  155b answer did not target exact child [transcript=%s]\n' \
      "$(cat "$AXDIR/transcript.jsonl")"; fail=$((fail + 1))
    failures+=("155b answer exact child")
  fi

  # --- 156. answer rejects non-answerable child sessions such as a review/audit
  # child (only execute / apply-review / doc-write children pause for answers). ---
  CSESS="answer-review-session"; CSDIR="$CEREBRO_HOME/sessions/$CSESS"
  mkdir -p "$CSDIR/children"; : > "$CSDIR/transcript.jsonl"
  jq -n --arg repo "$REPO" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{auditkey: {id:"REVIEW-CHILD", provider:"opencode", role:"audit", repo:$repo,
                    branch:"audit", status:"done", updated_at:$ts}}' \
        > "$CSDIR/child-sessions.json"
  STDERR_CONTAINS="not an answerable opencode child" \
  run_case 156 "answer review/audit child rejected" 1 -- \
    env CEREBRO_SESSION_ID="$CSESS" "$CEREBRO_BIN" answer REVIEW-CHILD "go"
else
  for t in 154 155 155b 156; do
    printf 'SKIP  %s  answer resume (opencode stub unavailable)\n' "$t"
  done
fi

# --- 157. parse_stream survives a closed stderr preview pipe. ---
PRS="$WORKDIR/parse-stream-result"
PIS="$WORKDIR/parse-stream-id"
{
  printf '%s\n' '{"type":"step_start","sessionID":"PARSE-1","part":{"type":"step-start"}}'
  printf '%s\n' '{"type":"tool_use","sessionID":"PARSE-1","part":{"type":"tool","tool":"bash","callID":"c1","state":{"status":"completed","input":{"command":"echo parse"},"output":"parse"}}}'
  printf '%s\n' '{"type":"text","sessionID":"PARSE-1","part":{"type":"text","text":"ok"}}'
  printf '%s\n' '{"type":"step_finish","sessionID":"PARSE-1","part":{"type":"step-finish","reason":"stop"}}'
} | { python3 "$here/../lib/python/parse_stream.py" "$PRS" "$PIS" 2>&1; } | python3 -c 'pass' >/dev/null
prsrc=$?
if [[ $prsrc -eq 0 && "$(cat "$PRS" 2>/dev/null)" == "ok" && "$(cat "$PIS" 2>/dev/null)" == "PARSE-1" ]]; then
  printf 'PASS  157  parse_stream survives closed stderr preview pipe\n'; pass=$((pass + 1))
else
  printf 'FAIL  157  parse_stream died on closed stderr [rc=%d result=%s id=%s]\n' \
    "$prsrc" "$(cat "$PRS" 2>/dev/null)" "$(cat "$PIS" 2>/dev/null)"; fail=$((fail + 1))
  failures+=("157 parse_stream closed stderr :: rc=$prsrc")
fi

# ========================================================================
# plan (orchestrator-written) and audit argument validation. `cerebro plan`
# spawns no child: it records markdown the orchestrator composed, like
# `spec set`. `cerebro audit` is the read-only child that checks a plan.
# ========================================================================

# --- 158. plan: blank content rejected ---
STDERR_CONTAINS="usage: cerebro plan" \
run_case 158 "plan blank content rejected" 1 -- "$CEREBRO_BIN" plan "   "

# --- 159. plan records the markdown and echoes the path ---
plan_out="$("$CEREBRO_BIN" plan "# My plan

Do the thing." --out my-plan 2>/dev/null)"
if [[ "$plan_out" == "$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID/plans/my-plan.md" ]] \
   && grep -q '# My plan' "$plan_out" && grep -q 'Do the thing.' "$plan_out"; then
  printf 'PASS  159  plan records content and echoes the path\n'; pass=$((pass + 1))
else
  printf 'FAIL  159  plan did not record content [out=%s]\n' "$plan_out"; fail=$((fail + 1))
  failures+=("159 plan record :: out=$plan_out")
fi

# --- 160. plan: same --out overwrites (the revision flow) ---
"$CEREBRO_BIN" plan "# Revised plan" --out my-plan >/dev/null 2>&1
if grep -q '# Revised plan' "$plan_out" && ! grep -q 'Do the thing.' "$plan_out"; then
  printf 'PASS  160  plan --out same name overwrites the file\n'; pass=$((pass + 1))
else
  printf 'FAIL  160  plan --out did not overwrite [file=%s]\n' "$(cat "$plan_out" 2>/dev/null)"; fail=$((fail + 1))
  failures+=("160 plan overwrite")
fi

# --- 161. audit: missing/empty plan file rejected ---
STDERR_CONTAINS="plan file missing or empty" \
run_case 161 "audit missing plan rejected" 1 -- \
  "$CEREBRO_BIN" audit "$REPO" "$WORKDIR/no-such-plan.md"

# --- 162. audit: relative repo path rejected ---
STDERR_CONTAINS="must be absolute" \
run_case 162 "audit relative repo rejected" 1 -- \
  "$CEREBRO_BIN" audit relative "$plan_out"

# --- 163. audit: unknown arg rejected ---
STDERR_CONTAINS="unknown arg" \
run_case 163 "audit unknown arg rejected" 1 -- \
  "$CEREBRO_BIN" audit "$REPO" "$plan_out" --bogus

# --- 164. plans rm deletes a plan dropped from a suite ---
"$CEREBRO_BIN" plans rm my-plan >/dev/null 2>&1
plans_list="$("$CEREBRO_BIN" plans 2>/dev/null)"
if [[ ! -e "$plan_out" && "$plans_list" != *"my-plan.md"* ]]; then
  printf 'PASS  164  plans rm deletes the plan file\n'; pass=$((pass + 1))
else
  printf 'FAIL  164  plans rm left the plan behind [list=%s]\n' "$plans_list"; fail=$((fail + 1))
  failures+=("164 plans rm")
fi

# --- 165. plans rm: missing plan rejected ---
STDERR_CONTAINS="no such plan" \
run_case 165 "plans rm missing plan rejected" 1 -- "$CEREBRO_BIN" plans rm nope

# --- 166. plans rm is confined to the session plans dir ---
printf 'outside\n' > "$WORKDIR/outside.md"
STDERR_CONTAINS="no such plan" \
run_case 166 "plans rm path-confined to plans dir" 1 -- \
  "$CEREBRO_BIN" plans rm "$WORKDIR/outside.md"
if [[ -e "$WORKDIR/outside.md" ]]; then
  printf 'PASS  166b plans rm did not touch a file outside the plans dir\n'; pass=$((pass + 1))
else
  printf 'FAIL  166b plans rm deleted an outside file\n'; fail=$((fail + 1))
  failures+=("166b plans rm escaped the plans dir")
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if (( fail > 0 )); then
  printf '\nFailures:\n'
  for f in "${failures[@]}"; do printf '  %s\n' "$f"; done
  exit 1
fi
exit 0
