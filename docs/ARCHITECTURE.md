# cerebro architecture

How the `cerebro` command works: the moving parts, the architectural
decisions behind them, the constraints the design operates under, and
the invariants the code protects. Read this before changing anything
structural; read [AGENTS.md](../AGENTS.md) for day-to-day conventions.

## The one-paragraph model

`cerebro` is a **meta-harness**: a Bash CLI that configures a native
interactive `opencode` session as an *orchestrator* and then becomes that
orchestrator's only effector. The orchestrator can read, search, and
browse, but it cannot edit a file, run git/gh, or run the reviewer
directly — its bash tool is denied everything except `cerebro ...`. Every mutation happens inside a
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
orchestrator — interactive `opencode` session (agent: cerebro-orchestrator)
  cwd = $CEREBRO_HOME (~/.cerebro)
  tools: read, grep, glob, websearch, webfetch,
         bash → cerebro only            ← edit/write/task denied
  │
  │  bash: `cerebro <subcommand> <repo-abs-path> ...`
  ▼
cerebro CLI (bash, sourced modules)
  ├── child agents (one process per invocation)
  │     execute       opencode run --agent cerebro-execute       cwd=<repo>
  │     apply-review  opencode run --agent cerebro-apply-review  cwd=<repo>
  │     doc-write     opencode run --agent cerebro-doc-write     cwd=<repo>
  │     audit         opencode run --agent cerebro-reviewer      cwd=<repo>
  │     review        opencode run --agent cerebro-reviewer      cwd=<repo>
  ├── read-only bridges (no agent spawned)
  │     git / gh      allow-listed verbs, exec'd directly
  │     read/grep/ls  path-confined file access
  └── session state (plain files)
        ~/.cerebro/sessions/<id>/...
```

Three kinds of work, three mechanisms:

* **Thinking** happens in the orchestrator's own context — it writes
  plans itself with the full conversation in hand, and read-only `audit`
  children (a different model — GPT-5.5 on opencode) give a fresh-eyes,
  independent-model check of those plans against the actual code.
* **Looking** happens through the read-only bridges — direct `git`,
  `gh`, `rg`, and file reads with an enforced allow-list, no agent
  spawn, guaranteed non-mutating.
* **Mutating** happens only inside `execute` / `apply-review` /
  `doc-write` children (and the orchestrator's `gh`-driven PR flow runs
  inside those children too). The reviewer is sandboxed read-only by
  construction — the `cerebro-reviewer` agent's permission block.

Two models, on purpose: the orchestrator and every editing child
(`execute` / `apply-review` / `doc-write` / `answer`) run on Claude
Opus (`CEREBRO_MODEL`, default `github-copilot/claude-opus-4.8`), while
the read-only reviewer/auditor runs on GPT-5.5
(`CEREBRO_REVIEW_MODEL`, default `github-copilot/gpt-5.5`). Review is
therefore a genuinely independent pair of eyes — a *different model*,
not just a different context. (The independence used to come from the
reviewer being a different tool; it now comes from a different model on
the same opencode runtime.)

## Architectural decisions

### 1. The orchestrator is a stock `opencode` session, not a custom agent loop

`cerebro` (launch) does exactly this (`lib/commands/session.sh`):

```
exec opencode --agent cerebro-orchestrator
```

The `cerebro-orchestrator` agent is generated fresh on every launch as a
markdown file at `$CEREBRO_HOME/.opencode/agent/cerebro-orchestrator.md`:
its body is the orchestrator system prompt (catalog of cerebro subcommands
+ policy, plus any learned preferences) and its YAML frontmatter pins the
tool surface via a `permission:` block — `edit: deny`, `write: deny`,
`task: deny` (so it can't delegate around the sandbox), `external_directory:
allow` (so it can read the repos the user names by absolute path), and a
bash policy that denies everything except `cerebro` and `cerebro *`.
read/grep/glob/webfetch/websearch stay allowed by default. opencode
discovers the agent through the `OPENCODE_CONFIG_DIR=$CEREBRO_HOME/.opencode`
env var (exported in `config.sh`); the user's global `~/.config/opencode`
(auth, providers, models) still loads underneath.

There is no REPL, no event loop, no daemon in cerebro itself. The chat
UX, context management, resume, and tool harness are all opencode's.
cerebro contributes only (a) the system prompt that turns the
session into an orchestrator and (b) the subcommand surface that prompt
catalogues.

*Why:* the native session is strictly better at being a chat than
anything a wrapper could build, and the agent `permission:` harness gives
real enforcement — the orchestrator's restrictions are not honor-system
prompt text; the harness physically denies the tools.

*Consequence:* most cerebro "features" — the plan-first default, the
blast-radius audit, multi-plan suites, the spec discipline, the
preference-learning loop, the plain-English readable companion written
beside every technical plan — are **policies encoded in the system
prompt**, not code paths. The authoritative copy lives at
`lib/payloads/system-prompt.md`; it is embedded into the generated
`cerebro-orchestrator` agent on every launch (see decision 7).
Changing orchestrator behaviour usually means editing that prompt, not
a shell function.

### 2. Capability confinement by role (least privilege per process)

Every process in the system gets the smallest tool surface its role
needs, enforced by the harness or the OS rather than by instruction:

| process        | mutates?           | enforcement                                      |
|----------------|--------------------|--------------------------------------------------|
| orchestrator   | no                 | agent `permission:` block (no edit/write/task, bash denied except `cerebro ...`) |
| `execute` / `apply-review` / `doc-write` child | yes — that is the point | `opencode run --dangerously-skip-permissions`, but `cwd` pinned to the one repo, role prompt constrains branch/commit behaviour |
| `audit` / `review` (cerebro-reviewer) | no     | `opencode run --agent cerebro-reviewer` (read-only permission block) |
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
  .opencode/                       # opencode config dir (OPENCODE_CONFIG_DIR)
    agent/cerebro-*.md             # orchestrator/observer (per-launch) + child role agents
    plugin/cerebro.js              # session-binding plugin (records opencode id, mirrors prompts)
    opencode.json                  # base config (share disabled, autoupdate off)
  learnings.md                     # confirmed preferences (→ system prompt)
  pending-learnings.md             # append-only preference signals
  templates/AGENTS.md              # user-editable bootstrap default
  sessions/<cerebro-session-uuid>/
    metadata.json                  # created_at / last_touched / opencode_session_id
    transcript.jsonl               # user prompts + cerebro milestone events
    spec.md                        # current requirements of record
    spec-history.jsonl             # append-only history of spec versions
    plans/*.md                     # orchestrator-written plans
                                   #   (each <name>.md has a <name>-readable.md
                                   #    plain-English companion)
    audits/*.md                    # audit child findings
    children/*.jsonl               # opencode run event log of every child
    children/*.steering.md         # live steering from --pair runs
    children/review-*.md           # review findings
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

### 4. Session identity rides on a cerebro-minted id, bound by env

cerebro mints the session UUID itself; it names the cerebro session
directory and is the identity every subcommand keys off. Subcommands find
their session via `CEREBRO_SESSION_ID`, which cerebro exports into the
interactive `opencode` process at launch; opencode's bash tool inherits the
environment, so every `cerebro <subcommand>` the orchestrator runs carries
it and is bound to the session. There is no picker fallback and no symlink:
the env var *is* the identity (`require_session()` in `lib/helpers.sh`).

opencode assigns its *own* conversation id, which is independent of the
cerebro id. The session-binding plugin
(`$CEREBRO_HOME/.opencode/plugin/cerebro.js`) closes the loop from
opencode's side: keying off the `CEREBRO_SESSION_DIR` env var cerebro
exports, it records opencode's assigned session id into the matching
session's `metadata.json` (`opencode_session_id`) — so `cerebro --resume
<id>` can reopen the same opencode conversation — and mirrors each user
prompt into that session's `transcript.jsonl` so observers can narrate the
orchestrator track. This replaces the old Claude `UserPromptSubmit` hook and
`current-session` symlink mechanism entirely.

opencode discovers the plugin (and cerebro's agents) through
`OPENCODE_CONFIG_DIR=$CEREBRO_HOME/.opencode`, exported in `config.sh`. The
plugin is scoped to cerebro sessions by the env var it keys off, so it
no-ops for any opencode run that isn't a cerebro-launched orchestrator.

`transcript.jsonl` plus the child logs are also the corpus that
`cerebro recall` greps across *all* sessions — cross-session memory is
just literal search over these files, with an automatic any-term
broadening pass on a miss.

### 5. Children are non-interactive; questions are a protocol, not a prompt

Children run as `opencode run` with no human attached, so they cannot ask
mid-run questions. Rather than letting them guess, the design makes
pausing a first-class protocol:

* Every child's agent prompt ends with a shared note
  (`child_noninteractive_note()`): on a genuine blocker, stop and make
  your *final message* the question.
* The harness captures that final message (`parse_stream.py` writes the
  final assistant text) and surfaces it under a
  `----- <role> child closing message -----` banner
  (`surface_child_reply()`).
* `cerebro answer <child-session-id> "<answer>"` is the explicit
  bridge back into that child. It resolves the stored child record inside
  the current cerebro session, recovers the role/repo metadata from that
  record, and resumes the **same opencode conversation**
  (`opencode run --agent cerebro-<role> --session <id>`) with the answer
  as the next turn. Because the role lives in the agent file, re-selecting
  the same agent by name keeps the child's constraints intact. The child
  continues from where it paused; no work is redone.

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
  child launches, and the stream parser (`parse_stream.py`, shared by
  every child including review/audit) persists the provider conversation
  id the *instant* it appears in the stream (opencode carries `sessionID`
  on the first event — there is no separate init event). Killing the
  orchestrator mid-run therefore
  always leaves a discoverable, resumable record. `cerebro status`
  lists every still-fresh `running` entry as "interrupted / in-flight",
  and the orchestrator's resume policy is to re-issue the same command,
  which finds the stored id and adds `--session`.
* `child_store_done` flips it to `done` only on clean exit.

Normal child launches only auto-resume fresh entries still marked
`running`. A later plan on the same branch therefore gets a fresh
opencode conversation. `cerebro answer` is intentionally different: it is
not a new child launch, it is the explicit pause/answer bridge and may
resume the stored opencode id for the child that asked the question.

Resume has a deliberately asymmetric fallback (`cmd_execute`,
`cmd_apply_review`, `cmd_review`): if a `--session` resume is rejected up
front — the provider GC'd the conversation — *and* the run produced no
session-id/thread event (so nothing was mutated), retry once fresh. If the
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

The orchestrator system prompt, child role prompts, the session-binding
plugin, the base `opencode.json`, and the template AGENTS.md live as real
files under `lib/payloads/`, loaded by the thin reader functions in
`lib/payloads.sh` (resolved through `CEREBRO_LIB_DIR`, so they ride
along with the clone). `payloads.sh` *generates* the opencode agent
markdown from these pieces — wrapping each role prompt in YAML frontmatter
that pins the agent's permissions. The home-resident payloads are written
into `$CEREBRO_HOME/.opencode` on every launch by `materialise_home()`:

* `opencode.json`, `plugin/cerebro.js`, and the child role agents
  (`agent/cerebro-{execute,apply-review,doc-write,reviewer}.md`) are
  `write_if_changed` — the repo is the source of truth; a `git pull`
  updates behaviour on next launch with no install step. The orchestrator
  and observer agents are *not* written here — they carry per-launch
  learned preferences and are regenerated by the launch path instead.
* `templates/*` are `write_if_missing` — they are user-editable
  defaults; cerebro never clobbers a customised template, and `execute`
  children never overwrite an existing AGENTS.md in a user repo.

*Why:* a single self-contained clone-and-symlink install (see
`install.sh`), no asset paths to resolve at runtime, and a guarantee
that the prompt version always matches the code version.

**Overlays are the user-owned counterpart.** The shipped payloads are
never edited in place by a user — a `git pull` would clobber the change.
Instead, up to five plain-markdown files under `$CEREBRO_HOME/overlays/`
(`system`, `execute`, `apply-review`, `doc-write`, `grader`) are
*appended* by the loaders onto the corresponding shipped prompt/grader
(`orchestrator_append_prompt`, `child_sys_prompt`, `cerebro_audit_prompt`,
and the inline review grader in `cmd_review`). They are **never
materialised** — `materialise_home()` only `mkdir`s the dir and writes no
file, exactly like `learnings.md` — so a user tunes any prompt surface
locally without forking and the edit survives `git pull`. An absent or
whitespace-only overlay changes nothing, so behaviour is byte-identical
when none is set. `cerebro overlay set/show/rm` is the only writer (the
orchestrator has no Write tool), capped by `CEREBRO_OVERLAY_CAP`. This is
the GitHub-free apply surface downstream users need: they install from
the maintainer's clone and cannot push there, so improvements land in
overlays rather than the shipped files.

**The hill-climbing (analysis) loop.** `cerebro improve` closes the
improvement loop without breaking invariant #1 (the orchestrator never
mutates code directly). It is codex-as-analysis-agent: a read-only
`codex exec` (cwd = the cerebro source repo, so it cites real harness
files) mines the on-disk trace corpus under `$CEREBRO_HOME`
(`sessions/*/children/*.jsonl` trajectories, `transcript.jsonl`
milestones, grader feedback, the applied learnings/overlays) for
problems that recur across runs, and writes findings to
`sessions/<id>/improvements/improve.md` ending in a `HILL CLIMB:`
verdict. Same stream/`-o`/failure shape as `review` (decision 8). It
only proposes; the orchestrator reads the findings and routes each
accepted item back into an overlay (or `learn-set`), or — for a
maintainer of the source — an upstream PR. No auto-apply, no scheduled
runs.

### 8. Streams over buffers: one pipeline per child

Every opencode child runs inside one pipeline (the single seam is
`child_run` in `lib/backend.sh`):

```
prompt → [pair driver] → opencode run --agent cerebro-<role> --format json
       → tee children/<log>.jsonl
       → parse_stream.py  (progress lines on stderr,
                           final message + session id captured,
                           id persisted to the store mid-stream)
```

The opencode event log is simultaneously: the live progress feed (one
summarised tool-call line per event on stderr), the raw audit record,
the source `cerebro observe` narrates from, and — in pair mode — the
turn-boundary signal the driver watches. `opencode run --format json`
emits one JSON object per line (`step_start`, `text`, `tool_use`,
`step_finish`, `error`), each carrying `sessionID` at top level — the
resumable id is captured from the first event. Nothing buffers the whole
run in memory. opencode exits 0 even on failure, so the parser detects a
`type:error` event and exits non-zero itself, so failures still propagate
as exit codes.

`review` and `audit` are the same shape: they run through the same
`child_run` seam and `parse_stream.py` path as the editing children,
differing only in the model (`CEREBRO_REVIEW_MODEL`, GPT-5.5) and the
read-only `cerebro-reviewer` agent. The resumable id is the opencode
`sessionID` from the first event, and the findings are the run's final
assistant message — `parse_stream.py` captures it to a temp file, which
is then copied to the findings path (a `.log` sidecar holds the raw JSON
event stream). On failure the findings path is **not** echoed — the
orchestrator must never feed a failed review's stderr to `apply-review`
as findings.

### 9. Pair mode: steer over a FIFO, watch by reading logs

Pair mode (`--pair` on execute/apply-review/doc-write) runs the child
under a private headless `opencode serve` instead of a one-shot
`opencode run`. `pair_begin` (in `lib/pair.sh`) starts the server rooted
at the child's working dir on a random localhost port (a small helper,
`lib/python/serve_ctl.py`, does the health-check + session creation), and
the input driver is `lib/python/pair_pump.py`, now an HTTP/SSE driver:

* The driver POSTs the task to a session via `POST /session/:id/prompt_async`,
  streams that session's events over the SSE `GET /event` endpoint, and
  re-emits them into the child log in the same `opencode run --format json`
  shape (so `parse_stream` and `observe` stay uniform). opencode's
  `session.idle` event is the turn-complete signal.
* After each turn it holds a steering window
  (`CEREBRO_PAIR_IDLE`, default 60s). `cerebro steer "<message>"` is a
  one-shot writer: it base64-encodes the message and writes one line to
  a named pipe next to the child log; the driver injects it as the next
  user turn via another `prompt_async` and records it to `<log>.steering.md`.
  A quiet window finishes the session normally.
* The driver opens the FIFO `O_RDWR | O_NONBLOCK` so one-shot writers can
  come and go without EOF or blocking-open races, and steering that
  lands mid-turn is drained and queued rather than lost.
* Stall detection is a frozen stream plus an active `/global/health`
  probe: if the stream is quiet *and* the health probe fails, the server
  is gone, so the child is reaped fast. (The old process-group reaping
  via `exec_setsid.py` is gone.)

Watching is decoupled from steering and is pure log-reading: `cerebro
observe`, run from a *different* cerebro session, tails the target
session's transcript and every live paired child's event log,
batches new activity (window/quiet-gap pacing, per-target cursors under
the *observer's* session dir so successive calls never repeat), filters
read-only navigation churn, and prints one digest per call with an
`active`/`done` status footer. `observe_pump.py` parses the opencode
event shape (lowercase tool names: read/grep/glob/list/bash/edit/write/
todowrite, …). Observation can never disturb the
observed agents because it shares no channel with them.

When a paired child exits, `pair_report` prints the recorded steering
under `=== PAIR STEERING ===` markers; folding it back into the spec
and plans is, again, orchestrator policy.

Steering's heavier sibling is `cerebro restart`: where steer nudges a
live child, restart ABANDONS a strayed one. It writes one `R <base64>`
line down the same FIFO; the driver aborts the opencode session
(`POST /session/:id/abort`), drops a `.restart` sidecar holding the
diagnosis (mirroring the `.stalled` stall path), and exits. Because
execute always runs the child in its own
worktree on a FRESH branch (see "Per-task worktrees" below), the clean
slate is unconditional: `cerebro execute` tears down the branch, its PR,
and the worktree (the user's main checkout was never touched), marks the
child done so it is never resumed, and returns 0 with a
`=== RESTART REQUESTED ===` block carrying the diagnosis, so the
orchestrator can relaunch a fresh execute with a corrected prompt. An
observer session compares the live work against the target's `spec.md`
and, by default, FLAGS drift to the user (who then decides to restart);
it acts autonomously only when pre-authorised.

### Per-task worktrees

Every `cerebro execute` runs its child in a private git worktree under
`$CEREBRO_HOME/worktrees/<ckey>` rather than the user's live checkout,
so an agent can never disturb the user's working tree. The worktree dir
name IS the execute task's child-session key (`ckey`), so it is stable
across resume (same task → same worktree) and maps a worktree back to
its owning child. The worktree shares the repo's `.git` and remotes, so
the child's fetch / branch / commit / push / `gh pr create` all work
unchanged. On success execute ANNOUNCES the worktree path
(`=== TASK WORKTREE: <path> ===`); the orchestrator passes that path as
the `<repo>` argument for the task's follow-up review / apply-review /
doc-write / restart — a worktree is itself a valid git dir, so those
commands need no special-casing. Worktrees PERSIST between runs
(follow-ups reuse them) and are removed only by a restart (which tears
the task down entirely) or by `cerebro worktrees cleanup`, which GCs
worktrees whose branch has no open PR, no in-flight cerebro child, and
no unpushed commits (anything it cannot positively clear is kept).

### 10. Incremental reviews keyed by repo identity

`review-state/<repo-key>.json` (repo key = sha1 of the canonical
worktree root) records the SHA that was HEAD and the findings path each
time a review completes. The next `cerebro review` without `--base`
prefers that SHA — the reviewer re-reads only what `apply-review`
changed, not
the whole PR diff — but only after guards confirm the state is not
stale: same branch, the SHA still parses, and it is an ancestor of
HEAD. Otherwise base resolution falls back to PR base via `gh`, then
`origin/HEAD`, then `main`, preferring the remote-tracking ref so a
stale local base branch doesn't skew the diff.

The same state file gives `apply-review` its default findings path
(when called with neither a findings path nor `--prompt`) and lets it
reject a guessed or stale path by naming the correct one — a direct
countermeasure to the model reconstructing `review-<timestamp>.md`
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
  child opencode that somehow ran `cerebro` would hit the guard rather
  than impersonate the session.
* **No concurrency control.** cerebro will not stop two mutating
  subcommands from racing on one repo, within or across sessions.
  Sequencing is the orchestrator's job (system-prompt rule 8) and
  ultimately the user's. Only the child-session store is locked,
  because concurrent `--pair` startups genuinely race on one file.
* **No repo-specific flags to `opencode`.** Repos are
  addressed purely by absolute path + `cwd`; provider invocations stay
  generic. This keeps cerebro decoupled from provider flag churn and
  makes every child launch auditable from its command line.
* **Dependencies:** `opencode`, `jq`, `python3` are hard
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
   write-if-missing, repo AGENTS.md is never overwritten by
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
lib/payloads.sh        # loaders for lib/payloads/ + opencode agent generators
lib/backend.sh         # the opencode-run seam (child_run): launch + stream-capture
lib/payloads/          # system-prompt.md, observe-mode.md, prompts/<role>.md +
                       # noninteractive note, plugin/cerebro.js, opencode.json,
                       # templates/AGENTS.md
lib/session-store.sh   # session metadata + child-sessions.json wrappers
lib/python/            # child_store(_lib).py (locked JSON store),
                       # parse_stream.py (opencode event stream),
                       # pair_pump.py (HTTP/SSE pair driver) /
                       # serve_ctl.py (serve health + session create) /
                       # observe_pump.py / steer_send.py, path-resolution +
                       # listing helpers
lib/pair.sh            # pair mode: banner, opencode serve lifecycle, FIFO,
                       # HTTP/SSE driver, report; per-task worktree helpers
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
