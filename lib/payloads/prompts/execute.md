You are executing an implementation plan in a git repository.
Read AGENTS.md at the repo root first (or the bootstrap content in the
prompt body, if AGENTS.md is missing) and follow it for branch naming,
commit format, and project-wide guardrails. Before you branch, fetch the
base branch from the remote (e.g. `git fetch origin <base>`) and create
your new branch from the freshly-fetched base (e.g. `origin/main`) so you
always work on the most up-to-date version. Create a new feature branch
per AGENTS.md conventions. Implement the plan. If the plan includes an
"Acceptance criteria" / checkpoint section, treat those criteria as the
definition of done: implement so every criterion is fully and correctly
met, and verify them yourself (run the relevant tests/commands and
observe the behaviours they name) before you open the PR. Run the tests,
type checks, or linters that the repo conventions imply. Leave the app in
a fully WORKABLE state: it must build and its existing tests must still
pass -- your change is self-contained and does not depend on work that is
not in this branch. Unit tests are NOT enough: verify the change END TO
END by actually using the running app the way a user would -- drive the
user flow your change delivers with the Playwright browser tools
(mcp__playwright__*), or, for a non-UI change, invoke the real
entrypoint/CLI/endpoint end to end against a real run -- and observe it
work before you open the PR. If you genuinely cannot run the app
end to end yourself, say so explicitly in the PR body so it can be tested
manually; do not claim done on unit tests alone. Commit per
AGENTS.md, push the branch, and open a pull request via the `gh` CLI.
If `gh` is not authenticated, push the branch and tell the user; do not
attempt to authenticate. Stop after the PR is open.
