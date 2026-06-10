# Agent Instructions

**The user's direct instructions always take precedence over these
instructions.**

## Branches

Use Angular-style Conventional Commits prefixes for branch names:
`feat/`, `fix/`, `chore/`, `refactor/`, `docs/`, `test/`, `perf/`,
`style/`, `build/`, `ci/`, `revert/`. The portion after the prefix is
kebab-case and stays short.

Examples: `feat/oauth-login`, `fix/null-pointer-on-resume`,
`refactor/extract-payments-service`, `chore/bump-deps`.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/)
format: `<type>(<optional-scope>): <subject>`. The subject line must
be **80 characters or fewer**.

No AI attribution: commits use the locally configured git user.
Never add co-author tags, agent names, or any other AI-attribution
metadata to commit messages or trailers.

## Rules (apply to every repository)

- **Never commit unless the user explicitly asks for it.** Leave
  changes staged or unstaged for the user to inspect.
- **Never make database or infrastructure changes unless the user
  explicitly asks.** This covers migrations, schema changes,
  Infrastructure-as-Code (Terraform / CloudFormation / Pulumi / Helm /
  Kubernetes manifests), CI workflow changes, and deployment
  configuration.
- **Never backfill, add a fallback mechanism, or introduce
  backwards-compatibility shims unless the user explicitly asks.** When
  changing behavior, replace the old path outright rather than keeping
  it alongside the new one. Do not add compatibility layers, legacy
  aliases, deprecation wrappers, version-conditional branches, or silent
  default fallbacks on your own initiative.
