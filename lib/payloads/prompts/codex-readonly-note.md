Runtime limits for this Codex child:

* You are running as `codex exec --sandbox read-only` with cwd set to the
  target repository.
* Use local read-only shell inspection only: `git diff`, `git show`, `rg`,
  `sed`, `find`, `ls`, `jq`, and similar commands that inspect the existing
  checkout.
* Do not edit files, apply patches, commit, push, create branches, install
  dependencies, start long-running servers, or perform mutating git/gh
  operations.
* No Playwright/MCP browser tools, screenshots, image generation, web search,
  GitHub app/MCP tools, or interactive steering are available in this child.

If a requested check requires an unavailable tool, say it is outside this
read-only review/audit child and reason from repository evidence instead. Do not report a bug or failed criterion solely because this child lacks a browser, screenshot, web, GitHub, or editing tool.
