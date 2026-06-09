# cerebro lib: config
# global config: set -uo pipefail and CEREBRO_* env defaults
# Sourced by bin/cerebro; not meant to be executed directly.

set -uo pipefail

CEREBRO_HOME="${CEREBRO_HOME:-$HOME/.cerebro}"
CEREBRO_MODEL="${CEREBRO_MODEL:-}"
CEREBRO_REVIEW_MODEL="${CEREBRO_REVIEW_MODEL:-}"
CEREBRO_TIMEOUT="${CEREBRO_TIMEOUT:-0}"   # 0/empty/none/unlimited = no cap
CEREBRO_CODEX_CMD="${CEREBRO_CODEX_CMD:-codex}"
CEREBRO_DEBUG="${CEREBRO_DEBUG:-0}"
