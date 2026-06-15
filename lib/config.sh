# cerebro lib: config
# global config: set -uo pipefail and CEREBRO_* env defaults
# Sourced by bin/cerebro; not meant to be executed directly.

set -uo pipefail

CEREBRO_HOME="${CEREBRO_HOME:-$HOME/.cerebro}"
# The model the orchestrator and every editing child (execute / apply-review /
# doc-write / answer) run on. Latest Claude Opus by default.
CEREBRO_MODEL="${CEREBRO_MODEL:-github-copilot/claude-opus-4.8}"
# The model the read-only reviewer/auditor (cerebro review / cerebro audit) runs
# on -- a deliberately DIFFERENT model from the implementer, so the review is a
# genuinely independent pair of eyes. GPT-5.5 by default.
CEREBRO_REVIEW_MODEL="${CEREBRO_REVIEW_MODEL:-github-copilot/gpt-5.5}"
CEREBRO_TIMEOUT="${CEREBRO_TIMEOUT:-0}"   # 0/empty/none/unlimited = no cap
CEREBRO_OPENCODE_CMD="${CEREBRO_OPENCODE_CMD:-opencode}"
CEREBRO_DEBUG="${CEREBRO_DEBUG:-0}"

# cerebro ships its own opencode config tree (agents + plugin) under
# $CEREBRO_HOME/.opencode and points every opencode invocation -- the
# interactive orchestrator and every spawned child -- at it via
# OPENCODE_CONFIG_DIR. The user's global ~/.config/opencode (auth, providers,
# models) still loads underneath it, so credentials keep working; this dir only
# layers cerebro's agents and the session-binding plugin on top.
export OPENCODE_CONFIG_DIR="$CEREBRO_HOME/.opencode"
