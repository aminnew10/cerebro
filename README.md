# cerebro

**Talk to one agent; get planned, reviewed, verified pull requests.**

![cerebro demo](docs/demo.gif)

`cerebro` drops you into a `claude` chat configured as an
orchestrator. It can read, search, and browse — but never touch your
repos directly: every edit, git operation, PR, and code review happens
in a short-lived sub-agent it spawns (`claude -p` for code, `codex
exec` for review and plan audits). The orchestrator writes plans itself
with its full conversation context, then has codex audit them against
the actual code with fresh, independent eyes. You describe what you
want and stay in the chat.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/aminmarashi/cerebro/main/install.sh | bash
cerebro
```

Name a repo by path, describe the change, read the plan it drafts, say
"go". Requires `claude`, `codex`, `jq`, `python3` (plus `git`/`gh` for
the PR work, `rg` recommended).

## What you get

* **Planned, reviewed PRs** — plan → your "go" → branch, PR, codex
  review loop, fixes applied, docs updated.
* **Verified, not just green** — done means the change was observed
  working in the running app (Playwright or with you), never unit
  tests alone.
* **Big changes as stacked PRs** — large specs become an ordered plan
  suite, one shippable PR per step, checkpoint-gated.
* **Watch & steer live agents** — pair with a running agent, observe
  it narrated from another session, inject course corrections.
* **Nothing lost** — sessions resume; interrupted children continue
  where they stopped; blocked children pause with a question instead
  of guessing.
* **It learns you** — durable preferences carried into every future
  session, across repos.

How to drive each of these: **[docs/USAGE.md](docs/USAGE.md)**.
How it works inside — design, decisions, constraints:
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Uninstall

```bash
cerebro-uninstall            # removes the symlink + PATH block
cerebro-uninstall --purge    # also deletes the clone; session state is never touched
```

## Development

```bash
bash tests/run.sh
```

Conventions live in [AGENTS.md](AGENTS.md); the demo GIF is rendered
from [docs/demo/demo.tape](docs/demo/demo.tape) with
[vhs](https://github.com/charmbracelet/vhs).
