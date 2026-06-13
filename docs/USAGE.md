# Using cerebro

Everything cerebro can do for you and how to drive it. You never type
`cerebro` subcommands yourself — you talk to the orchestrator in plain
English and it runs the machinery. For what happens under the hood,
see [ARCHITECTURE.md](ARCHITECTURE.md).

## Sessions

```bash
cerebro                       # mint a new session, drop into the chat
cerebro --resume <id>         # resume a specific session
cerebro --resume              # claude's session picker
cerebro --observe [<id>]      # watch-and-steer-only session for another
                              #   session's live paired children
cerebro list                  # list sessions, newest first
```

`cerebro --observe` opens an interactive chat dedicated to looking over the
shoulder of another session's live `--pair` children: it polls `cerebro
observe`, narrates the design taking shape, and steers an agent only when you
tell it to. Its tools are narrowed to `observe`/`steer` plus read-only
commands, so it makes no direct repo changes. It first waits until there is
something to observe -- a session with live paired children -- polling quietly
until one appears (Ctrl-C to cancel), so the chat opens onto live activity
rather than an immediate "nothing to observe". Pass a target session id and it
waits on, then narrates, that session; omit the id and it waits for any other
session to start live paired children (auto-picking the most recently active).

## Ship a feature (the core loop)

Describe the change and the repo. The orchestrator:

1. Records what you asked for as the **session spec** — the
   requirements of record (see [Guardrails](#guardrails-and-autonomy)).
2. Drafts a plan into the session's `plans/` dir and gives you the
   path. For high-blast-radius changes (many files, shared modules,
   public APIs, schemas, auth paths) it first **audits** the plan
   against the actual code — phantom targets, missed call sites, scope
   creep, over-engineering — and revises it before proposing it.
3. Waits for your explicit **"go"**.
4. Executes the plan in a sub-agent: fetches the base branch, creates
   a feature branch, implements, commits, pushes, opens a PR via `gh`.
   When `execute` is deliberately run with identical `--base` and
   `--branch` values, it instead updates that existing branch and its
   existing PR without creating another branch or PR. Omitting `--base`
   has the same effect when the current branch already equals `--branch`.
5. Runs codex review against the diff, summarises the findings,
   applies the in-scope important ones, and loops review →
   apply-review until codex is quiet. Re-reviews are incremental: only
   the changes since the last review are inspected, so the loop stays
   cheap. Out-of-scope or gold-plating findings are named to you, not
   silently applied.
6. **Verifies the change end to end by actually using the running
   app** — Playwright-driven where possible, or manual testing with
   you when it can't be automated. Static review and unit tests never
   count as "done" on their own.
7. Optionally updates docs on the same branch (`doc-write`).

First time it touches a repo with no `AGENTS.md`/`CLAUDE.md`, it adds
them from the user-editable templates at `~/.cerebro/templates/` as a
separate first commit (defaults: Conventional Commits, ≤ 80-char
subjects, `feat/`-style branches, no commits and no DB/infra changes
without an explicit ask). It never overwrites existing files.

## Ship a large change (stacked PRs)

Give it a spec too big for one coherent PR and it decomposes the work
into an **ordered suite of plans — one PR each**, stacked so each PR
branches off the previous one. Every step must satisfy the
**workable-state invariant**: each PR is independently shippable and
leaves the app building, green, and fully working — merging the stack
one PR at a time never leaves the app broken at any boundary. If the
spec can't be split that way, it says so and proposes a different cut
instead of emitting breaking plans.

You approve the decomposition once; it then executes the suite
autonomously. Each step is gated by a **checkpoint**: a codex review
fed the plan's acceptance criteria (verdict line `ACCEPTANCE CRITERIA:
MET` / `NOT MET`), zero important in-scope findings, *and* an
end-to-end check of that step's user flow against the running app. On
a failing checkpoint it makes up to three bounded corrective attempts
(scoped fixes, or replanning the failing step and its downstream
plans), then escalates to you. At the end you get the full PR stack,
ready to review and merge in order.

## Ask about a repo

"What does HEAD look like vs main?", "is CI green on the PR?", "where
is the retry logic?" — the orchestrator answers these without spawning
an agent, through guaranteed read-only bridges (`cerebro git`, `gh`,
`grep`, `read`, `ls`) that allow-list every verb and flag. It also
checks `cerebro recall` — a literal search across all your past
sessions' transcripts and agent logs — before re-asking you something
you already answered in a prior session.

## Pair: watch and steer a live agent

Ask to *pair* (or *watch*, *steer*, *let me drive*) and the child runs
in pair mode (`plan`, `execute`, `apply-review`, `doc-write`; codex
review has no live-steer):

* **Observe** — from a *second* cerebro session, say "observe
  \<session-id\>" (the id from the `PAIR MODE` banner; it names the
  orchestrator session, not a child). That session tails every live
  paired child at once and narrates in plain English what each one is
  doing — following the gist, flagging the decisions that matter (new
  abstractions, schema changes, security paths, public APIs) and
  quoting the shaping code. Observation only reads logs; it never
  disturbs the agents.
* **Steer** — `cerebro steer "<message>"` injects one instruction into
  the live child as its next turn and returns immediately. (Pass the
  pipe path from the banner first when several paired children run at
  once.) After each turn the child waits a short window
  (`CEREBRO_PAIR_IDLE`, default 60s) for steering; a quiet window lets
  it finish on its own.

When the child finishes, your steering is reported back and the
orchestrator folds it in automatically — updating the session spec and
revising affected plans — then tells you what changed.

## Resume and interrupted work

Sessions are durable. `cerebro --resume <id>` (or the picker) drops
you back into the same conversation, with the session spec, plans,
review state, and transcripts intact on disk.

Interrupting mid-run loses nothing: every child's resumable
conversation id is persisted the instant it starts. On "continue" the
orchestrator checks `cerebro status` for interrupted in-flight
children and resumes each one — continuing half-done work via
`--resume` instead of redoing it (and instead of duplicating commits).
Stored ids stay resumable for `CEREBRO_CHILD_SESSION_TTL` seconds
(default 24h), but normal child launches only auto-resume children still
marked in-flight. Once a child finishes cleanly, the next sub-agent starts
a fresh provider conversation even if it runs on the same repo and branch.

A child that hits a genuine blocker doesn't guess and doesn't die: it
**pauses with a question** as its closing message. The orchestrator
answers from the spec or past sessions when the record settles it, and
only relays to you when the decision is genuinely yours. The closing
message prints the child session id, and
`cerebro answer <child-session-id> "<answer>"` resumes that same child
exactly where it stopped.

## Teach it your preferences

When you reveal a general preference — directly ("always keep diffs
small") or by repeatedly correcting in the same direction — the
orchestrator records the signal, and once the evidence is clear (one
explicit directive, or the same signal twice) consolidates it into a
small global `learnings.md` that is injected into the system prompt of
**every future session**, across all repos. Ambiguous signals get a
clarifying question first. `cerebro learnings` (ask the orchestrator)
prints the active set.

## Skip the ceremony

Planning and review are the default, never skipped on the
orchestrator's own judgement. Say "just do it", "skip the plan", or
"fix it directly" and it uses the inline-prompt shortcuts instead —
straight to an editing child, no plan file or findings file in
between.

## Guardrails and autonomy

cerebro is built to be autonomous *within* your requirements, never
about them:

* **The session spec is the contract.** Before planning, the
  orchestrator records what you actually asked for; every requirement
  change updates it (prior versions are archived, never lost). It
  lives on disk, so it survives context compaction. During execution
  the orchestrator may adapt a plan that turns out wrong and keep
  going **as long as the adjusted work still satisfies the spec** — but
  anything that would (or even might) drop a requirement, change
  asked-for behaviour, or expand scope stops and asks you first. Doubt
  counts as divergence.
* **Plan-first by default.** Skipping the plan or the review requires
  you to ask for it explicitly.
* **The orchestrator cannot mutate anything.** Its tools are
  restricted to read/search/web plus `cerebro:*`; the restriction is
  enforced by the harness, not by promise. Mutations happen only in
  role-scoped children; the reviewer is sandboxed read-only.
* **Done means observed working.** End-to-end verification in the
  running app is a non-negotiable part of the definition of done.

## Install details

The installer clones into `~/.local/share/cerebro` (override with
`CEREBRO_SRC`), symlinks `cerebro` into `~/bin` (override with
`CEREBRO_BINDIR`), and adds that directory to your PATH if needed.
Re-running it updates the clone in place. To pin a ref, set
`CEREBRO_REF`.

Prefer to manage it yourself:

```bash
git clone https://github.com/aminmarashi/cerebro.git ~/.local/share/cerebro
ln -s ~/.local/share/cerebro/bin/cerebro ~/bin/cerebro   # ~/bin must be on PATH
```

To uninstall without a working `cerebro-uninstall` symlink:

```bash
curl -fsSL https://raw.githubusercontent.com/aminmarashi/cerebro/main/uninstall.sh | bash
```

## Configuration

Env vars (all optional):

| var | meaning | default |
|-----|---------|---------|
| `CEREBRO_HOME` | base dir for all state | `~/.cerebro` |
| `CEREBRO_MODEL` | model alias for child `claude -p` | provider default |
| `CEREBRO_REVIEW_MODEL` | model alias for `codex exec` | provider default |
| `CEREBRO_TIMEOUT` | wall-clock cap (s) per child call | `0` (no cap, so e2e runs and CI waits are never killed) |
| `CEREBRO_CHILD_SESSION_TTL` | how long (s) a stored child id stays resumable | `86400` (24h) |
| `CEREBRO_PAIR_IDLE` | steering window (s) after each paired turn | `60` |
| `CEREBRO_CODEX_CMD` | codex executable | `codex` |
| `CEREBRO_DEBUG` | `1` for verbose logs | `0` |

Two deliberate limits to know about:

* **Interactive-only.** `cerebro` refuses to run under a non-terminal
  parent (pipes, scripts, cron). The sub-agents the orchestrator
  spawns are exempt.
* **No concurrency control.** cerebro won't stop you from running two
  mutating operations against the same repo at once, within or across
  sessions — sequence your own mutating work.

## Session state

Everything durable is a plain file under `$CEREBRO_HOME` (default
`~/.cerebro/`), and the orchestrator will happily hand you paths to
open in your editor:

```
~/.cerebro/
  learnings.md                       # confirmed preferences (injected into the prompt)
  templates/AGENTS.md, CLAUDE.md     # defaults dropped into new repos (edit freely)
  sessions/<id>/
    spec.md                          # current session spec (requirements of record)
    spec-history.jsonl               # every prior spec version
    plans/                           # plan markdown files
    children/                        # stream-json logs of every sub-agent + codex findings
    review-state/                    # per-repo last-reviewed SHA
```

The full layout, the hook that routes prompts to the right session,
and the reasoning behind file-based state are covered in
[ARCHITECTURE.md](ARCHITECTURE.md#3-everything-durable-is-a-plain-file).
