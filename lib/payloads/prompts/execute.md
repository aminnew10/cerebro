You are executing an implementation plan in a git repository.
Read AGENTS.md at the repo root first (or the bootstrap content in the
prompt body, if AGENTS.md is missing) and follow it for branch naming,
commit format, and project-wide guardrails. Before you branch, fetch the
base branch from the remote (e.g. `git fetch origin <base>`) and create
your new branch from the freshly-fetched base (e.g. `origin/main`) so you
always work on the most up-to-date version. Create a new feature branch
per AGENTS.md conventions. (You are running inside an isolated git
worktree dedicated to this task; the shared .git and remotes mean fetch,
push, and gh work normally.) Implement the plan. If the plan includes an
"Acceptance criteria" / checkpoint section, treat those criteria as the
definition of done: implement so every criterion is fully and correctly
met, and verify them yourself (run the relevant tests/commands and
observe the behaviours they name) before you open the PR. Run the tests,
type checks, or linters that the repo conventions imply. Leave the app in
a fully WORKABLE state: it must build and its existing tests must still
pass -- your change is self-contained and does not depend on work that is
not in this branch. Unit tests are NOT enough: verify the change END TO
END by actually using the running app the way a user would -- drive the
user flow your change delivers with a Playwright MCP browser tool (if one
is configured), or, for a non-UI change, invoke the real
entrypoint/CLI/endpoint end to end against a real run -- and observe it
work before you open the PR; do not claim done on unit tests alone. Commit
per AGENTS.md. Push the branch and open a pull request via the `gh` CLI.

Write the PR DESCRIPTION as a plain-English account, for a reviewer who
needs to understand your intent, of the decisions you made and why -- not a
re-description of the diff. Cover, in plain prose or short bullets:
- The intent: what this change sets out to accomplish and why it was
  needed -- the problem or requirement it satisfies.
- The key decisions you made while implementing, each paired with its
  rationale: why you chose this approach, what alternatives you considered
  and rejected, and any trade-offs or constraints that shaped the choice.
- Anything a reviewer needs in order to judge the change that is NOT
  obvious from the diff: assumptions you made, follow-ups you deliberately
  deferred, and areas that warrant closer review.
Do NOT restate, enumerate, or walk through the code changes file-by-file
or line-by-line -- the reviewer can read the diff. The body is for the
reasoning behind the diff, not a re-description of it; avoid mechanical
change-logs ("modified X, added Y to Z") unless naming a change is
necessary to explain a decision. If you genuinely could not verify the
change end to end yourself, say so explicitly in the body as a
clearly-marked testing note, so the user can test it manually.

If `gh` is not authenticated, push the branch and tell the user; do not
attempt to authenticate. Stop after the PR is open.
