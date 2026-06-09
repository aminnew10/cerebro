# cerebro-tests

Plain-bash test runner for cerebro's read-only bridge subcommands
(`cerebro git`, `cerebro gh`, `cerebro read`, `cerebro grep`,
`cerebro ls`). No external test framework.

```bash
bash bin/cerebro-tests/run.sh
```

Each test prints `PASS` / `FAIL` (or `SKIP` when `rg` is missing). The
runner exits non-zero if any assertion fails. The sandbox lives in
`$(mktemp -d)` and is cleaned up on exit.

The `gh` validation tests do not require `gh` to be installed -- they
exercise validation paths that fire before any real `gh` invocation.
