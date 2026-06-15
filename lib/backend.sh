# cerebro lib: backend
# The single seam between cerebro's command modules and the opencode CLI that
# runs the mutating children (execute / apply-review / doc-write / answer).
# Everything claude-specific that used to be scattered across the command
# pipelines lives here now: how a child is launched, how its event stream is
# captured to the child log, and how the resumable session id is parsed back.
# Sourced by bin/cerebro; not meant to be executed directly.

# child_run_opts <agent> <resume-id> <model> -- build the opencode-run flag
# array for a child of the given agent into the caller-scoped CHILD_RUN_OPTS
# array. We pass --format json so opencode streams its event objects (parsed by
# parse_stream.py), --dangerously-skip-permissions so the non-interactive child
# never blocks on an approval prompt (its agent frontmatter still denies nothing
# it needs), the model (editing children run Opus, the reviewer runs GPT-5.5),
# and --session to resume an in-flight child.
CHILD_RUN_OPTS=()
child_run_opts() {
  local agent="$1" resume="${2:-}" model="${3:-}"
  CHILD_RUN_OPTS=(run --agent "$agent" --format json --dangerously-skip-permissions)
  [[ -n "$model" ]] && CHILD_RUN_OPTS+=(--model "$model")
  [[ -n "$resume" ]] && CHILD_RUN_OPTS+=(--session "$resume")
}

# child_run <pair> <cwd> <prompt> <agent> <resume-id> <child_log> <msg_capture>
# <id_capture> <store_file> <ckey> [model] -- run one attempt of a child and
# return its exit code. Unpaired: launch `opencode run` with the prompt as its
# positional message, tee the JSON event stream to <child_log>, and pipe it
# through parse_stream.py (which captures the session id + closing message and
# exits non-zero on an opencode error). Paired: hand off to pair_run, which
# drives the child through a headless `opencode serve` so it can be watched and
# steered live. <model> defaults to CEREBRO_MODEL (the editing model); the
# read-only reviewer passes CEREBRO_REVIEW_MODEL instead. The session-scoped env
# vars are stripped so the child is never mistaken for an orchestrator-context
# caller.
child_run() {
  local pair="$1" cwd="$2" prompt="$3" agent="$4" resume="$5" \
        child_log="$6" msg_capture="$7" id_capture="$8" store_file="$9" ckey="${10}"
  local model="${11:-$CEREBRO_MODEL}"

  if (( pair )); then
    pair_run "$cwd" "$prompt" "$agent" "$resume" \
      "$child_log" "$msg_capture" "$id_capture" "$store_file" "$ckey" "$model"
    return $?
  fi

  child_run_opts "$agent" "$resume" "$model"
  ( cd "$cwd" && env -u CEREBRO_SESSION_ID -u CEREBRO_SESSION_DIR \
      "${TIMEOUT_CMD[@]}" "$CEREBRO_OPENCODE_CMD" "${CHILD_RUN_OPTS[@]}" "$prompt" </dev/null 2>/dev/null \
      | tee "$child_log" \
      | python3 "$CEREBRO_LIB_DIR/python/parse_stream.py" \
          "$msg_capture" "$id_capture" "$store_file" "$ckey" )
  return $?
}
