# cerebro architecture

How the `cerebro` command works: the moving parts, the architectural
decisions behind them, the constraints the design operates under, and
the invariants the code protects. Read this before changing anything
structural; read [AGENTS.md](../AGENTS.md) for day-to-day conventions.

## The one-paragraph model

`cerebro` is a **meta-harness**: a Bash CLI that configures a native
interactive `claude` session as an *orchestrator* and then becomes that
orchestrator's only effector. The orchestrator can read, search, and
browse, but it cannot edit a file, run git, or call codex — its Bash
tool is restricted to `cerebro:*`. Every mutation happens inside a
short-lived, non-interactive child agent that `cerebro` spawns with a
role-scoped tool surface and `cwd` pinned to the target repo. All
durable state — the session spec, plans, child logs, review state,
resumable child-session ids, learned preferences — lives as plain files
under `~/.cerebro/`, so it survives context compaction, interrupts, and
process death. The intelligence is in the prompts; the safety is in the
harness.

## Big picture

```
you (terminal)
  │  natural-language chat
  ▼
orchestrator — interactive `claude` session
  cwd = $CEREBRO_HOME (~/.cerebro)
  tools: Read, Grep, Glob, WebSearch, WebFetch,
         mcp__playwright__*, Bash(cerebro:*)        ← nothing else
  │
  │  Bash: `cerebro <subcommand> <repo-abs-path> ...`
  ▼
cerebro CLI (bash, sourced modules)
  ├── child agents (one process per invocation)
  │     execute       claude -p   Read/Edit/Write/Bash...  cwd=<repo>
  │     apply-review  claude -p   Read/Edit/Write/Bash...  cwd=<repo>
  │     doc-write     claude -p   Read/Edit/Write/Bash...  cwd=<repo>
  │     audit         codex exec  --sandbox read-only      cwd=<repo>
  │     review        codex exec  --sandbox read-only      cwd=<repo>
  ├── read-only bridges (no agent spawned)
  │     git / gh      allow-listed verbs, exec'd directly
  │     read/grep/ls  path-confined file access
  └── session state (plain files)
        ~/.cerebro/sessions/<id>/...
```

Three kinds of work, three mechanisms:

* **Thinking** happens in the orchestrator's own context — it writes
  plans itself with the full conversation in hand, and read-only `audit`
  children (codex) give a fresh-eyes, independent-model check of those
  plans against the actual code.
* **Looking** happens through the read-only bridges — direct `git`,
  `gh`, `rg`, and file reads with an enforced allow-list, no agent
  spawn, guaranteed non-mutating.
* **Mutating** happens only inside `execute` / `apply-review` /
  `doc-write` children (and the orchestrator's `gh`-driven PR flow runs
  inside those children too). The reviewer (`codex`) is sandboxed
  read-only by construction.

## Architectural decisions

### 1. The orchestrator is a stock `claude` session, not a custom agent loop

`cerebro` (launch) does exactly this (`lib/commands/session.sh`):

```
exec claude \
  --session-id <uuid> \
  --append-system-prompt "<catalog of cerebro subcommands + policy>" \
  --allowedTools "Bash(cerebro:*) Read Grep Glob WebSearch WebFetch mcp__playwright__*"
```

There is no REPL, no event loop, no daemon in cerebro itself. The chat
UX, context management, resume picker, and tool harness are all
claude's. cerebro contributes only (a) the system prompt that turns the
session into an orchestrator and (b) the subcommand surface that prompt
catalogues.

*Why:* the native session is strictly better at being a chat than
anything a wrapper could build, and the `--allowedTools` harness gives
real enforcement — the orchestrator's restrictions are not honor-system
prompt text; the harness physically lacks the tools.

*Consequence:* most cerebro "features" — the plan-first default, the
blast-radius audit, multi-plan suites, the spec discipline, the
preference-learning loop — are **policies encoded in the system
prompt**, not code paths. The authoritative copy lives at
`lib/payloads/system-prompt.md`; it is materialised to
`~/.cerebro/system-prompt.md` on every launch (see decision 7).
Changing orchestrator behaviour usually means editing that prompt, not
a shell function.

### 2. Capability confinement by role (least privilege per process)

Every process in the system gets the smallest tool surface its role
needs, enforced by the harness or the OS rather than by instruction:

| process        | mutates?           | enforcement                                      |
|----------------|--------------------|--------------------------------------------------|
| orchestrator   | no                 | `--allowedTools` (no Edit/Write, Bash is `cerebro:*` only) |
| `execute` / `apply-review` / `doc-write` child | yes — that is the point | `--permission-mode bypassPermissions`, but `cwd` pinned to the one repo, role prompt constrains branch/commit behaviour |
| `audit` / `review` (codex) | no     | `codex exec --sandbox read-only`                 |
| bridges        | no                 | verb/flag allow-lists, path confinement, `execve` (no shell) |

The mutating children are deliberately *un*confined inside their repo —
they must branch, edit, run tests, commit, push, and open PRs — so the
design contains them differently: one repo per invocation (absolute
path is always the first positional argument, `cwd` is set to it), one
mutating child per repo at a time (a documented invariant the
orchestrator must sequence — see Constraints), and a non-interactive
role prompt that forbids the moves the harness cannot (touching
AGENTS.md, switching branches in follow-up roles).

The bridges deserve a note: `cerebro git` / `cerebro gh` are not
"trusted commands" — they validate the subcommand and every flag
against explicit allow/deny lists (`lib/commands/git.sh`,
`lib/commands/gh.sh`), reject path-escape options (`diff --no-index`,
`blame --contents`, `gh api -X`, ...), and invoke the real binary via
`execve` so shell metacharacters in arguments are inert. `cerebro
read` / `grep` / `ls` resolve every path through `resolve_in_repo()`
(realpath + prefix check, exit 6 on escape) or `resolve_bare_abs()`
(refuses `/dev`, `/proc`, `/sys` and non-regular files). The exit-code
contract is documented in the system prompt so the model can interpret
failures programmatically.

### 3. Everything durable is a plain file

There is no database and no in-memory state that matters. The layout:

```
~/.cerebro/
  system-prompt.md                 # copied from lib/payloads/system-prompt.md
  hook.sh                          # UserPromptSubmit hook (from lib/payloads/)
  .claude/settings.local.json      # registers the hook
  learnings.md                     # confirmed preferences (→ system prompt)
  pending-learnings.md             # append-only preference signals
  templates/AGENTS.md, CLAUDE.md   # user-editable bootstrap defaults
  current-session -> sessions/<id> # symlink, maintained by the hook
  sessions/<claude-session-uuid>/
    metadata.json                  # created_at / last_touched
    transcript.jsonl               # user prompts + cerebro milestone events
    spec.md                        # current requirements of record
    spec-history.jsonl             # append-only history of spec versions
    plans/*.md                     # orchestrator-written plans
    audits/*.md                    # audit child findings
    children/*.jsonl               # stream-json log of every child
    children/*.steering.md         # live steering from --pair runs
    children/codex-*.md            # review findings
    child-sessions.json            # resumable provider ids + run status
    review-state/<repo-key>.json   # last-reviewed SHA + last findings path
```

*Why:* the orchestrator is an LLM whose context gets compacted. Any
fact that must outlive compaction — what the user actually asked for,
which plan is current, what was already reviewed, which child can be
resumed — has to live outside the context window, in a place the
orchestrator can re-read (`cerebro spec`, `cerebro status`, plain
`Read`). Files are also user-inspectable: the README promises the user
can open any plan, transcript, or findings file in their editor.

The **session spec** (`spec.md`) is the keystone of this decision: it
is the requirements of record every plan adjustment is measured
against. Plans are expected not to survive contact with the code:
detail-level deviations proceed with a narration note, but a plan-level
discovery (a step unworkable as written, a false assumption, a
decomposition that no longer fits) stops the work — the orchestrator
informs the user and waits. On "adjust and continue" it reconciles the
whole plan set: already-executed plans get the newly discovered facts
folded into their text (their work is never re-executed), future plans
get the adjustments, and steps are added, removed (`cerebro plans rm`),
or replaced as needed before execution resumes. The spec itself may
never silently change; it survives on disk and every replacement
archives the prior version to `spec-history.jsonl` first
(`lib/commands/spec.sh`).

### 4. Session identity rides on claude's session id

cerebro mints the UUID itself and passes it as `--session-id`, so the
claude conversation id and the cerebro session directory name are the
same string. Subcommands find their session via `CEREBRO_SESSION_ID`,
which the orchestrator's environment inherits and every Bash tool call
carries.

The `UserPromptSubmit` hook closes the loop from claude's side: on each
user prompt it appends `{kind:"user", ts, text}` to the matching
session's `transcript.jsonl` (routing by the `session_id` in the hook
payload) and repoints the `current-session` symlink. That symlink is
the fallback identity for the bare `cerebro --resume` path, where
claude's own picker chooses the session and cerebro doesn't learn the
id until the first prompt fires the hook (`require_session()` in
`lib/helpers.sh`).

The hook is registered in `~/.cerebro/.claude/settings.local.json` —
the orchestrator always runs with `cwd=$CEREBRO_HOME`, so the
project-local settings apply. The hook no-ops for any session id that
has no directory under `sessions/`, which makes it safe even though
that settings file is visible to any claude run started in
`~/.cerebro`.

`transcript.jsonl` plus the child logs are also the corpus that
`cerebro recall` greps across *all* sessions — cross-session memory is
just literal search over these files, with an automatic any-term
broadening pass on a miss.

### 5. Children are non-interactive; questions are a protocol, not a prompt

Children run as `claude -p` with no human attached, so they cannot ask
mid-run questions. Rather than letting them guess, the design makes
pausing a first-class protocol:

* Every child's system prompt ends with a shared note
  (`child_noninteractive_note()`): on a genuine blocker, stop and make
  your *final message* the question.
* The harness captures that final message (`parse_stream.py` writes the
  `result` event text) and surfaces it under a
  `----- <role> child closing message -----` banner
  (`surface_child_reply()`).
* `cerebro answer <child-session-id> "<answer>"` is the explicit
  bridge back into that child. It resolves the stored child record inside
  the current cerebro session, recovers the role/repo metadata from that
  record, and resumes the **same provider conversation**
  (`claude --resume <id>`) with the answer as the next turn, re-passing
  the identical role system prompt so the child's constraints stay
  intact. The child continues from where it paused; no work is redone.

The orchestrator's policy (system prompt) layers on top: answer from
the spec/plan/recall when the record settles it, relay to the user only
when the decision is genuinely theirs.

### 6. Resumability: persist the child id at start, not at exit

`sessions/<id>/child-sessions.json` maps a **child key** — sha1 of
`repo + role + discriminator` (for execute, branch plus plan path or
inline prompt; for branch-local roles, branch; for audit, output name) —
to `{id, provider, role, repo, branch, log, status, started_at,
updated_at}`.

Two timing decisions make interruption safe:

* `child_store_begin` marks the entry `status=running` *before* the
  child launches, and the stream parsers (`parse_stream.py` for claude,
  `codex_capture.py` for codex) persist the provider conversation id
  the *instant* it appears in the stream (claude's `init` event,
  codex's `thread.started`). Killing the orchestrator mid-run therefore
  always leaves a discoverable, resumable record. `cerebro status`
  lists every still-fresh `running` entry as "interrupted / in-flight",
  and the orchestrator's resume policy is to re-issue the same command,
  which finds the stored id and adds `--resume`.
* `child_store_done` flips it to `done` only on clean exit.

Normal child launches only auto-resume fresh entries still marked
`running`. A later plan on the same branch therefore gets a fresh
provider conversation. `cerebro answer` is intentionally different: it is
not a new child launch, it is the explicit pause/answer bridge and may
resume the stored provider id for the child that asked the question.

Resume has a deliberately asymmetric fallback (`cmd_execute`,
`cmd_apply_review`, `cmd_review`): if a `--resume` is rejected up front
— the provider GC'd the conversation — *and* the run produced no
init/thread event (so nothing was mutated), retry once fresh. If the
resumed run started and then failed, the failure is fatal: a fresh
re-run of a mutating role would duplicate half-applied work. TTL
(`CEREBRO_CHILD_SESSION_TTL`, default 24h) bounds how long a stored id
is trusted at all.

All store access goes through one python entry point
(`lib/python/child_store.py`) that takes an exclusive `fcntl` flock on a sidecar
`.lock` and rewrites the JSON atomically (`mkstemp` + `os.replace`), so
concurrent `--pair` children persisting their ids at startup cannot
clobber each other.

### 7. Payloads are versioned files, materialised at launch

The hook script, settings.json template, orchestrator system prompt,
child role prompts, and template AGENTS.md/CLAUDE.md live as real files
under `lib/payloads/`, loaded by the thin reader functions in
`lib/payloads.sh` (resolved through `CEREBRO_LIB_DIR`, so they ride
along with the clone). The home-resident ones are written into
`$CEREBRO_HOME` on every launch by `materialise_home()`:

* `system-prompt.md`, `hook.sh`, `settings.local.json` are
  `write_if_changed` — the repo is the source of truth; a `git pull`
  updates behaviour on next launch with no install step.
* `templates/*` are `write_if_missing` — they are user-editable
  defaults; cerebro never clobbers a customised template, and `execute`
  children never overwrite an existing AGENTS.md in a user repo.

*Why:* a single self-contained clone-and-symlink install (see
`install.sh`), no asset paths to resolve at runtime, and a guarantee
that the prompt version always matches the code version.

### 8. Streams over buffers: one pipeline per child

Every claude child runs inside one pipeline:

```
prompt → [pair pump] → claude -p --output-format stream-json
       → tee children/<log>.jsonl
       → parse_stream.py  (progress lines on stderr,
                           final message + session id captured,
                           id persisted to the store mid-stream)
```

The stream-json log is simultaneously: the live progress feed (one
summarised tool-call line per event on stderr), the raw audit record,
the source `cerebro observe` narrates from, and — in pair mode — the
turn-boundary signal the input pump watches. Nothing buffers the whole
run in memory, and the parser exits non-zero when claude reports a
non-`success` result so failures propagate as exit codes.

`review` is the same shape with codex: `--json` events on stdout (the
only place the resumable `thread_id` appears) are teed and scanned by
`codex_capture.py`, while `-o` writes the human-readable findings file.
On failure the findings path is **not** echoed — the orchestrator must
never feed a failed review's stderr to `apply-review` as findings.

### 9. Pair mode: steer over a FIFO, watch by reading logs

Pair mode (`--pair` on execute/apply-review/doc-write) swaps the
child's plain-text stdin for claude's `--input-format stream-json` and
inserts an input pump (`lib/python/pair_pump.py`):

* The pump emits the task as the first user message, then watches the
  child's log for each turn-ending `result` event.
* After each turn it holds the child's stdin open for a steering window
  (`CEREBRO_PAIR_IDLE`, default 60s). `cerebro steer "<message>"` is a
  one-shot writer: it base64-encodes the message and writes one line to
  a named pipe next to the child log; the pump forwards it as the next
  user turn and records it to `<log>.steering.md`. A quiet window
  closes stdin and the child finishes normally.
* The pump opens the FIFO `O_RDWR | O_NONBLOCK` so one-shot writers can
  come and go without EOF or blocking-open races, and steering that
  lands mid-turn is drained and queued rather than lost.

Watching is decoupled from steering and is pure log-reading: `cerebro
observe`, run from a *different* cerebro session, tails the target
session's transcript and every live paired child's stream-json log,
batches new activity (window/quiet-gap pacing, per-target cursors under
the *observer's* session dir so successive calls never repeat), filters
read-only navigation churn, and prints one digest per call with an
`active`/`done` status footer. Observation can never disturb the
observed agents because it shares no channel with them.

When a paired child exits, `pair_report` prints the recorded steering
under `=== PAIR STEERING ===` markers; folding it back into the spec
and plans is, again, orchestrator policy.

### 10. Incremental reviews keyed by repo identity

`review-state/<repo-key>.json` (repo key = sha1 of the canonical
worktree root) records the SHA that was HEAD and the findings path each
time a review completes. The next `cerebro review` without `--base`
prefers that SHA — codex re-reads only what `apply-review` changed, not
the whole PR diff — but only after guards confirm the state is not
stale: same branch, the SHA still parses, and it is an ancestor of
HEAD. Otherwise base resolution falls back to PR base via `gh`, then
`origin/HEAD`, then `main`, preferring the remote-tracking ref so a
stale local base branch doesn't skew the diff.

The same state file gives `apply-review` its default findings path
(when called with neither a findings path nor `--prompt`) and lets it
reject a guessed or stale path by naming the correct one — a direct
countermeasure to the model reconstructing `codex-<timestamp>.md`
filenames from memory.

### 11. Benign-missing semantics on the exploration bridges

The orchestrator fans out parallel bridge calls, and one failed call in
a batch can cancel its siblings. So for `read` / `grep` / `ls`, an
in-bounds "target doesn't exist / wrong type / zero matches" is **not
an error**: the bridge prints a machine-recognisable marker —
`(not found: <path>)` or `(no matches)` — to stdout and exits 0
(`missing_target()` in `lib/helpers.sh`). `--strict-missing` restores
hard semantics (exit 3; rg-native exit 1 for zero matches).

Security refusals are exempt by design: path escapes and special-path
reads (`/dev`, `/proc`, `/sys`) stay hard errors (exit 6) regardless of
mode, and `resolve_bare_abs` distinguishes the benign case with a
dedicated exit 7 sentinel so callers cannot accidentally soften a
refusal. The `git`/`gh` bridges keep ordinary error propagation.

### 12. Bash + Python helpers, sourced modules, thin entry point

The CLI is Bash because it is glue: argument shapes, pipelines, exec.
Anything needing real data structures — JSON stores, stream parsing,
locking, path canonicalisation — is Python 3, kept as real files under
`lib/python/` and invoked by absolute path (`python3
"$CEREBRO_LIB_DIR/python/<name>.py"`), chosen over jq-only because the
store needs flock + atomic rename and the parsers need stateful
line-by-line logic. Only genuine one-liners stay inline in the shell;
`jq` handles the simple JSON one-liners. The store-backed scripts
import `child_store_lib.py` (with `sys.dont_write_bytecode` set first,
so no `__pycache__` lands in the source tree).

`bin/cerebro` resolves its own symlink chain by hand (macOS has no
`readlink -f`), sources `lib/config.sh` first (the only
ordering-sensitive module: `set -uo pipefail` + env defaults), then
every other module in any order — they are pure function/string
definitions — and calls `main`. The dispatch table in `lib/main.sh`
maps each subcommand to a `cmd_*` function; adding a subcommand means a
new file in `lib/commands/` plus one route line.

## Constraints

These are environmental or deliberate limits the design accepts:

* **Interactive-only at the top level.** `cerebro` refuses to run under
  a non-terminal parent (pipes, scripts, cron) via `require_interactive()`
  — a TTY check plus a parent-process allow-list. Sub-agents are exempt
  through `CEREBRO_SESSION_ID`, which is exactly how subcommands run
  inside the orchestrator's non-TTY Bash tool. Children themselves are
  launched with `env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR` so a
  child claude that somehow ran `cerebro` would hit the guard rather
  than impersonate the session.
* **No concurrency control.** cerebro will not stop two mutating
  subcommands from racing on one repo, within or across sessions.
  Sequencing is the orchestrator's job (system-prompt rule 8) and
  ultimately the user's. Only the child-session store is locked,
  because concurrent `--pair` startups genuinely race on one file.
* **No repo-specific flags to `claude` or `codex`.** Repos are
  addressed purely by absolute path + `cwd`; provider invocations stay
  generic. This keeps cerebro decoupled from provider flag churn and
  makes every child launch auditable from its command line.
* **Dependencies:** `claude`, `codex`, `jq`, `python3` are hard
  requirements (`require_deps`); `git`/`gh` are needed by the bridges
  and the mutating children; `rg` is recommended for `cerebro grep`.
  macOS portability is a standing constraint (hand-rolled realpath /
  readlink, `timeout` → `gtimeout` → `perl alarm` fallback chain in
  `build_timeout_cmd`).
* **No wall-clock cap by default.** `CEREBRO_TIMEOUT` defaults to 0 so
  long-running children (browser-driven e2e verification, CI waits) are
  never killed mid-mutation; setting a cap is the user's explicit
  choice.
* **System-prompt size.** `learnings.md` is injected into the
  orchestrator's system prompt on every launch, so `learn-set` rejects
  content over ~1600 chars. The prompt also forces consolidation
  (rewrite, dedupe) over append.
* **Children cannot prompt the user.** Accepted, and converted into the
  pause/answer protocol (decision 5) rather than worked around with
  pseudo-interactive hacks.

## Invariants worth protecting

If you change code in this repo, do not break these:

1. **The orchestrator never mutates anything directly.** Any new
   capability that edits files or runs side-effecting commands must be
   a child role or stay out.
2. **Bridges are provably read-only.** New `git`/`gh` verbs or flags go
   through the allow-list with the same scrutiny (no path-escape, no
   write forms, no arbitrary-code options like `gh extension install`).
3. **A child's provider id is persisted before/as it starts**, never
   only at exit — interruption safety depends on it.
4. **A failed review never echoes a findings path**, and apply-review
   never accepts a findings path that doesn't exist without naming the
   correct one.
5. **Mutating resume never silently re-runs fresh after partial work.**
   The "retry fresh only if no init event" rule is the line between
   convenience and duplicated commits.
6. **Security refusals stay hard** (exit 6) even where benign-missing
   softening exists.
7. **Spec history is append-only**; `spec set` archives before it
   replaces.
8. **User-customised files are never clobbered**: templates are
   write-if-missing, repo AGENTS.md/CLAUDE.md are never overwritten by
   children.
9. **Stdout contracts are stable.** Subcommands that echo a path
   (`plan`, `audit`, `review`, `execute`'s child log) keep stdout clean of
   anything else; human chatter goes to stderr (`say`/`warn`). The
   orchestrator parses stdout.

## Module map

```
bin/cerebro            # entry point: resolve symlink, source lib, main "$@"
lib/config.sh          # set -uo pipefail + CEREBRO_* defaults (sourced first)
lib/helpers.sh         # say/warn/die, exit-code helpers, path/repo resolution,
                       # interactive guard, timeout chain, home materialiser
lib/payloads.sh        # thin loaders for the files under lib/payloads/
lib/payloads/          # hook.sh, settings.json template, system-prompt.md,
                       # prompts/<role>.md + noninteractive note,
                       # templates/AGENTS.md, CLAUDE.md
lib/session-store.sh   # session metadata + child-sessions.json wrappers
lib/python/            # child_store(_lib).py (locked JSON store),
                       # parse_stream.py (claude stream), codex_capture.py
                       # (codex stream), pair_pump.py / observe_pump.py /
                       # steer_send.py, path-resolution + listing helpers
lib/pair.sh            # pair mode: banner, FIFO lifecycle, input pump, report
lib/commands/*.sh      # one file per subcommand group; each defines cmd_*
lib/main.sh            # dispatch table argv → cmd_*
install.sh             # clone to ~/.local/share/cerebro, symlink into ~/bin
uninstall.sh           # remove symlink + PATH block; --purge removes clone
tests/run.sh           # plain-bash suite (bridges, spec/learn/session store)
```

Exit-code contract, tool catalogues, and orchestrator policy all live
in `lib/payloads/system-prompt.md` — when
behaviour and prompt must agree (e.g. bridge exit codes), the prompt is
the documented contract and the code must match it.

## Testing

`bash tests/run.sh` — a plain-bash, no-framework suite that builds a
sandbox under `mktemp -d` and exercises the surfaces where a regression
is dangerous rather than cosmetic: the read-only bridge allow-lists and
path guards (`git`, `gh`, `read`, `grep`, `ls`), benign-missing vs
strict semantics, and the spec / learning / child-session store
machinery. The `gh` tests don't require `gh` installed — they target
validation that fires before any real invocation. Run it before
proposing changes (AGENTS.md).
