# cerebro

Meta-harness for the plan → execute → review loop. Typing `cerebro` in
a shell drops you into a native interactive `claude` session configured
as an orchestrator: a restricted tool surface (Read, Grep, Glob, and
Bash limited to `cerebro:*`) plus a system prompt that catalogues a
small set of `cerebro <subcommand>` tools. The orchestrator spawns
short-lived sub-agents on your behalf — `claude -p` for planning and
code work, `codex exec` for review — while you stay in the chat.

```bash
cerebro                       # mint a new session, drop into the chat
cerebro --resume <id>         # resume a specific session
cerebro --resume              # claude's session picker
cerebro list                  # list sessions, newest first
```

## Install

`cerebro` is a Bash CLI split across a small library, so it installs by
cloning the repo and symlinking the entry point onto your PATH (rather
than copying a single file):

```bash
curl -fsSL https://raw.githubusercontent.com/aminmarashi/cerebro/main/install.sh | bash
```

The installer clones into `~/.local/share/cerebro` (override with
`CEREBRO_SRC`), symlinks `cerebro` into `~/bin` (override with
`CEREBRO_BINDIR`), and adds that directory to your PATH if it isn't
already there. Re-running it updates the clone in place. To pin a ref,
set `CEREBRO_REF`.

Prefer to manage it yourself:

```bash
git clone https://github.com/aminmarashi/cerebro.git ~/.local/share/cerebro
ln -s ~/.local/share/cerebro/bin/cerebro ~/bin/cerebro   # ~/bin must be on PATH
```

## Uninstall

```bash
cerebro-uninstall
# or, before installing:
curl -fsSL https://raw.githubusercontent.com/aminmarashi/cerebro/main/uninstall.sh | bash
```

This removes the `cerebro` symlink and the PATH block the installer
added. It leaves the cloned source and your session state under
`~/.cerebro/` in place; pass `--purge` (or set `CEREBRO_PURGE=1`) to also
delete the clone. Session state is never touched.

## Requirements

`claude`, `codex`, `jq`, `python3`. The orchestrator also calls
`git`/`gh`/`rg` directly through read-only bridge subcommands (`cerebro
git`, `cerebro gh`, `cerebro grep`, `cerebro read`, `cerebro ls`) so it
can inspect a user repo without spawning a planning child; `git` and
`gh` are needed for those bridges, and `rg` (ripgrep) is recommended for
`cerebro grep`. Child claudes additionally need `git` and `gh` for
`execute` / `apply-review` / `doc-write` to function.

## How it works

You talk only to the orchestrator. It decides when to call `cerebro
plan`, `cerebro execute`, `cerebro review`, `cerebro apply-review`,
`cerebro doc-write`, `cerebro answer` (resume a child that paused with a
question), `cerebro recall`, `cerebro status`, the session
spec (`cerebro spec`, `spec set`, `spec history`), or the
preference-learning subcommands (`cerebro learnings`, `learn-note`,
`learn-set`) based on the conversation. A typical feature loop: describe the change → the
orchestrator drafts a plan and tells you where it landed → you read
the plan and say "go" → orchestrator executes it on a feature branch,
pushes, opens a PR via `gh` → orchestrator runs codex against the
diff, summarises the findings, and applies the ones that matter → loop
until codex is quiet → **verifies the change end to end by actually using
the running app** (Playwright, or manual testing with you when it can't be
driven automatically) → optionally `doc-write` at the end. Codex review is
static, so it never counts as done on its own — unit tests passing is
necessary but not sufficient; the work is done only once the behaviour has
been observed working in the real app.

**Session spec & mid-flight adaptation.** Before planning, the
orchestrator records what you actually asked for — the specification and
its requirements — as the session's *requirements of record* with
`cerebro spec set`. Every time you add or change a requirement it sets
the spec again: the newest text replaces the current spec, and the prior
version is archived first, so the full history of how the requirements
evolved is preserved (`cerebro spec` prints the current spec; `cerebro
spec history` prints every version oldest-first). The spec lives as plain
files under `sessions/<id>/` (`spec.md` + `spec-history.jsonl`), so it
**survives context compaction** — the orchestrator re-reads it whenever
it is unsure what the task requires. This is what makes autonomous
course-correction safe: during execution, when a plan turns out wrong,
hits a wall, or a better path appears, the orchestrator may **adjust the
plan and keep going without re-prompting you — as long as the adjusted
work still satisfies the session spec**. If a change would, or even
*might*, diverge from the spec (dropping a requirement, changing
asked-for behaviour, expanding scope, trading away something the spec
implies you care about), it treats that doubt as divergence and **stops
to ask you** — then captures the resolution back into the spec before
resuming. Autonomy covers *how* the spec is satisfied, never *what* the
spec asks for.

**Blast-radius audit.** When a change is high blast radius — it touches
many files, a shared module, a public API, a data model or migration,
auth/security paths, or it's a multi-plan suite — the orchestrator does
not hand you the plan the moment it's drafted. It first *audits* the plan
against the actual code (via the read-only `cerebro grep`/`read`/`git`
bridges): it checks that every named target really exists and that none
were missed, and that the plan hasn't crept in scope, over-engineered, or
misread the requirement. If it finds any of those, it revises the plan
(`cerebro plan --out <same-name>`) and re-checks, then proposes only a
plan that survived the audit. The audit precedes your approval; it never
replaces it. Localized, low-blast-radius changes skip the gate.

**Large specifications (multi-plan suites).** When a change is too big
for one coherent PR, the orchestrator breaks the spec into an *ordered
suite* of smaller plans — one PR each — and drives them with the
existing subcommands (no special command). Every plan must obey a
**workable-state invariant**: each is a self-contained, independently
shippable increment that leaves the app building, green, and fully
working on its own — merging the stack one PR at a time never leaves the
app broken at any boundary. If the spec cannot be split that way (every
ordering breaks the app mid-suite), the orchestrator does *not* emit
breaking plans — it stops and reports, proposing one larger plan or a
different cut instead. It drafts an overview plus one detailed plan per
step, each ending in an `## Acceptance criteria (checkpoint)` section
that includes both a still-builds/tests-pass check and an explicit
end-to-end usage check, then summarises the suite and waits for a single
"go". After approval it executes the plans in order as **stacked PRs**:
the first branches off `main`, each later one off the previous plan's
branch (`cerebro execute … --base <prev-branch> --branch <this-branch>`).
Each PR is gated by a **checkpoint** — `cerebro review …
--criteria-file <plan>` feeds the plan's acceptance criteria into a codex
review, which ends its findings with `ACCEPTANCE CRITERIA: MET` or
`NOT MET`. Because codex is static and never runs the app, the checkpoint
also requires an **end-to-end** verification — the orchestrator drives the
step's user flow against the running app with the Playwright tools (or has
the user confirm it manually when that's impossible). The orchestrator
advances to the next plan only when the criteria are met, no in-scope
finding remains, *and* the step works end to end. If mid-execution it
finds a step would leave the app broken, it stops and re-cuts the plans
rather than pushing a broken state forward. On a failing
checkpoint it makes up to three bounded corrective attempts — a scoped
`apply-review` when the implementation is buggy, or a *replan* (rewrite
the failing plan, and any downstream plans/criteria, via `cerebro plan
--out <same-name>`) when the plan's approach itself is wrong — then
stops and asks you. It runs autonomously through the stack between the
initial "go" and either the final PR or an escalation.

**AGENTS.md bootstrap.** The first time `cerebro execute` runs against
a repo that lacks `AGENTS.md` / `CLAUDE.md` at the root, it adds them
from the templates at `~/.cerebro/templates/` as a separate first
commit on the PR. The defaults set Conventional Commits with ≤ 80-char
subjects, Angular-style branch prefixes (`feat/`, `fix/`, `chore/`,
`refactor/`, …), no commits without an explicit ask, and no DB/infra
changes without an explicit ask. Edit
`~/.cerebro/templates/AGENTS.md` to customize what new repos get;
cerebro never overwrites an existing AGENTS.md in a user repo.

**Pair programming mode.** Ask the orchestrator to *pair* (or *watch* /
*steer* / *let me drive*) a child agent and it adds `--pair` to that
`cerebro plan`, `execute`, `apply-review`, or `doc-write` (codex
`review` has no live-steer, so pairing does not apply there). `--pair`
drives the child through claude's stream-json input so you can follow it
and redirect it:

- **`cerebro observe [<session-id>]`** — from **another** cerebro session,
  ask it to *observe* the paired session (the id from the `PAIR MODE`
  banner names that orchestrator session, not a child). That session tails
  *every* live paired child of the target at once and tells you, in plain
  English, what each one is doing — like a colleague watching over your
  shoulder: it follows the gist rather than every line and flags the
  important decisions (new abstractions, infra, schema, security, public
  APIs). It only reads the agents' logs, so observing never disturbs them;
  it returns one batch of activity per call and the observer loops, narrating
  until the children finish.
- **`cerebro steer "<message>"`** — a one-shot inject that sends a single
  instruction into the live child as its next turn and returns at once.
  Pass the pipe path from the child's `PAIR MODE` banner as a first
  argument (`cerebro steer <pipe> "<message>"`) only when several paired
  children are running at once.

The child runs to completion on its own; after each turn it waits a short
window (`CEREBRO_PAIR_IDLE`, default 60s) for steering, and a quiet
window finishes it — so a steer takes effect when it lands within that
window. The orchestrator runs paired children in the background and prints
the session id to observe (and the steer command) as soon as the banner
appears, so another session can connect while the work is still going. Each steering message is recorded
to a `.steering.md` beside the child log; when the child finishes, cerebro
reports the steering back and the orchestrator **folds it in
automatically** — updating the session spec (`cerebro spec set`) for any
changed requirement and revising the affected and upcoming plans (or
replanning) — and tells you what it changed. Your steering is treated as
a direct instruction; only a steer that changes *what* the spec asks for
in a genuinely ambiguous way is bounced back for confirmation.

**Paused children & `cerebro answer`.** Every spawned child (`plan`,
`execute`, `apply-review`, `doc-write`) runs non-interactively, so it
*cannot* ask a question mid-run — there is no human at its keyboard. Each
child is told that when it hits a genuine blocker (a decision with real
consequences it can't responsibly make alone) it should stop and end with
that question as its final message rather than guess. So a child command
can return having *not* finished: for `plan` the question lands in the
plan file; for the mutating roles the child's closing message is surfaced
under a `----- <role> child closing message -----` banner in the command
output. The orchestrator watches for this. When a child pauses with a
question it first tries to answer from the session spec, the plan, and
`cerebro recall`; only if the decision is genuinely the user's and nothing
on record settles it does it relay the question to you. It then delivers
the answer with `cerebro answer <repo> "<answer>" --role <role>`, which
**resumes the same child session** and feeds the answer as its next turn,
so the child continues exactly where it paused instead of redoing work.
When several children of the same role are live in one repo, the launch
discriminator disambiguates: `--branch` (`execute`/`apply-review`/
`doc-write`), `--plan` / `--for-prompt` (an `execute` started from a plan
file or inline prompt with no `--branch`), or `--out` (the plan name);
with none it auto-matches the single resumable session of that role.

**Scope-filtered review forwarding.** When summarising a `cerebro
review`, the orchestrator forwards only findings clearly within the
plan's scope to `cerebro apply-review`. Out-of-scope improvements
(unrelated refactors, nits in untouched files) are named to you but
not acted on; ambiguous findings prompt a clarifying question first.
`cerebro apply-review` with no findings path (and no `--prompt`)
defaults to the last review's findings file for the current
repo+branch; an explicit path that doesn't exist is rejected with the
correct last-review path named.

**Learned preferences.** cerebro builds a small, durable record of how
you like work done, so future sessions start already tuned to you. When
you reveal a general preference — directly ("always keep diffs small")
or indirectly (you keep asking it to simplify, or reject
over-engineered solutions) — the orchestrator logs a signal with
`cerebro learn-note` into a global `pending-learnings.md`. Once the
evidence is clear (one explicit directive, or the same signal seen on
two or more occasions) it consolidates the confirmed preferences into a
small `learnings.md` via `cerebro learn-set`; when a signal is
ambiguous it asks you first. `learnings.md` is injected into the
orchestrator's system prompt on every launch/resume, capped (~1600
chars) so it stays system-message-sized. Both files are global under
`~/.cerebro/` and persist across sessions and repos; `cerebro
learnings` prints the active set plus a pending-signal count.

**Incremental re-reviews.** After an `apply-review`, the next
`cerebro review` defaults to diffing against the SHA that was HEAD at
the time of the previous review, not `main`. Codex only re-evaluates
the new changes, so the review loop stays cheap. State lives under
`sessions/<id>/review-state/`; pass `--base` to override and force a
wider review.

**Interactive-only.** `cerebro` refuses to run under a non-terminal
parent (pipes, scripts, cron). Sub-agents are exempt via the
`CEREBRO_SESSION_ID` environment variable that the orchestrator inherits.

**Concurrency.** cerebro has no concurrency control. It will not stop
you from running two mutating subcommands (`execute`, `apply-review`,
`doc-write`) against the same repo at the same time, whether within a
single session or across sessions — sequence your own mutating work.

**No chat/PR/repo-specific flags are ever passed to `claude` or
`codex`.** The orchestrator addresses repos by absolute path as the
first positional argument to its sub-agent tools, and `cerebro` sets
each spawned child's `cwd` to that path. The orchestrator itself only
ever runs in `$CEREBRO_HOME`.

## Session state

Session state lives under `$CEREBRO_HOME` (default `~/.cerebro/`):

```
~/.cerebro/
  hook.sh                            # UserPromptSubmit hook, routes by session id
  system-prompt.md                   # orchestrator system prompt
  learnings.md                       # confirmed user preferences (injected into the prompt)
  pending-learnings.md               # append-only journal of preference signals
  .claude/settings.local.json        # registers the hook
  templates/
    AGENTS.md                        # default dropped into repos that lack one
    CLAUDE.md                        # default stub that links to AGENTS.md
  sessions/<claude-session-uuid>/
    metadata.json
    transcript.jsonl                 # user prompts + cerebro milestone events
    spec.md                          # current session spec (requirements of record)
    spec-history.jsonl               # append-only history of every spec version
    plans/                           # plan markdown files
    children/                        # stream-json logs of every sub-agent
                                     #   (+ <log>.steering.md from paired runs)
    review-state/                    # per-repo last-reviewed SHA + last findings path
```

The `UserPromptSubmit` hook routes each user message to the matching
session's `transcript.jsonl` by `session_id`, so memory survives
resume and concurrent sessions never bleed into each other. The hook
no-ops for non-cerebro claude sessions, so it is safe even though
`.claude/settings.local.json` lives in a directory claude visits any
time you `cd` into `~/.cerebro`.

For the read-only exploration bridges (`cerebro read`, `cerebro ls`,
`cerebro grep`), a benign in-bounds "target not found / wrong type"
(and, for `grep`, zero matches) is treated as a successful empty
result rather than an error: the bridge prints a `(not found: <path>)`
(or `(no matches)`) marker line to stdout and exits 0. This keeps a
missing probe target during the orchestrator's parallel fan-out from
cancelling sibling tool calls in the same batch. Pass `--strict-missing`
to restore the old hard behavior (exit 3 for a missing/wrong-type
target; rg-native exit 1 for zero matches). Path-escape and
special-path refusals (`/dev`, `/proc`, `/sys`) remain hard errors
(exit 6), and the `cerebro git` / `cerebro gh` bridges are unchanged.
The authoritative exit-code contract lives in the embedded
`cerebro_system_prompt()` heredoc (`lib/payloads.sh`), which regenerates
`~/.cerebro/system-prompt.md` on next launch.

## Configuration

Env: `CEREBRO_HOME`, `CEREBRO_MODEL`, `CEREBRO_REVIEW_MODEL`,
`CEREBRO_TIMEOUT`, `CEREBRO_CODEX_CMD`, `CEREBRO_CHILD_SESSION_TTL`,
`CEREBRO_DEBUG`.

`CEREBRO_TIMEOUT` is the wall-clock cap (seconds) on each child agent call. It defaults to `0` (no cap) so long-running children — Playwright login/browser driving, waiting on the build pipeline — are never killed. Set it to a positive integer to re-enable a cap.

Repeated `execute`/`review`/`apply-review`/`doc-write` calls on the same repo+branch resume the same underlying child conversation (claude `--resume` / `codex exec resume`). The provider session ids are stored per session under `sessions/<id>/child-sessions.json`, keyed by repo+role+branch (an `execute` without `--branch` keys on the plan path or inline prompt instead; a `plan` keys on its output name). `plan` persists its id too — not to resume on re-issue, but so a plan that paused with a question can be continued by `cerebro answer`. `CEREBRO_CHILD_SESSION_TTL` (seconds, default `86400` = 24h) bounds how long a stored id stays resumable; past it, or if the provider rejects the id, the child re-runs fresh and the store is refreshed.

The child id is persisted the **instant** the child starts — not when it finishes — and each entry tracks a `running`/`done` status. So if you interrupt the orchestrator while a child agent is running, the work is not lost: the child is left marked `running` (interrupted), and on the next launch/resume the orchestrator runs `cerebro status` — whose "interrupted / in-flight children" section lists every child that was mid-run — and resumes each by re-issuing the same command, continuing the half-done work via `--resume` instead of redoing it. Concurrent `--pair` children write to the store under an `fcntl` lock so their startup ids never clobber each other.

## Architecture

`cerebro` is a Bash CLI split into small sourced modules. `bin/cerebro`
is a thin entry point — it resolves its own path (through any PATH
symlink), sources the library under `lib/`, then dispatches:

```
bin/cerebro            # entry point: locate lib, source modules, run main
lib/config.sh          # shell options + CEREBRO_* env defaults (sourced first)
lib/helpers.sh         # say/warn/die, exit-code helpers, path + repo resolution, usage
lib/payloads.sh        # embedded hook, settings.json, system prompt, templates
lib/session-store.sh   # session metadata + child-agent session store
lib/python.sh          # inline python helpers (child-session persistence, stream parsing)
lib/pair.sh            # pair-programming mode (watch + steer a live child)
lib/commands/*.sh      # one file per subcommand group (plan, execute, review, ...)
lib/main.sh            # dispatch table mapping a subcommand to a cmd_* function
```

Only `config.sh` runs ordering-sensitive top-level code; every other
module is function and string definitions, so load order among them
does not matter.

## Tests

A plain-bash test suite exercises the read-only bridge subcommands
(`cerebro git`, `cerebro gh`, `cerebro read`, `cerebro grep`,
`cerebro ls`) plus the spec/learning/session-store machinery. No
external test framework:

```bash
bash tests/run.sh
```

See [tests/README.md](tests/README.md) for details.
