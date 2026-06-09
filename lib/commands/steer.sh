# cerebro lib: commands/steer
# subcommand: steer (one-shot inject into a paired child)
# Sourced by bin/cerebro; not meant to be executed directly.

# PY_STEER_SEND -- the one-shot steering inject for `cerebro steer`. argv is
# <fifo> <message>. It writes a single "S <base64>" line to the child'\''s pipe
# and returns; the pump forwards it as the child'\''s next user turn.
PY_STEER_SEND='
import base64, os, sys
fifo, msg = sys.argv[1], sys.argv[2]
try:
    fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
except OSError:
    sys.stderr.write("cerebro: the child is not listening (it may have finished).\n")
    sys.exit(3)
try:
    os.write(fd, ("S " + base64.b64encode(msg.encode("utf-8")).decode() + "\n").encode())
finally:
    os.close(fd)
'

# steer_fifo_live <fifo> -- true if the pipe exists AND the child's pump is
# still reading it (a writer-open succeeds), i.e. it is a live paired session
# rather than a stale pipe left by a crashed child.
steer_fifo_live() {
  [[ -p "$1" ]] || return 1
  python3 -c '
import os, sys
try:
    fd = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)
except OSError:
    sys.exit(1)
os.close(fd)
' "$1" 2>/dev/null
}

# ----- subcommand: cerebro steer [<pipe>] "<message>" ----------------------
# One-shot steering: inject a single instruction into a live `--pair` child and
# return at once (no attach, no lock). With ONE argument that argument is the
# message and the live paired session is found automatically (the common case);
# with TWO, the first is the <pipe> path from the child's PAIR MODE banner (to
# pick one when several run at once) and the second is the message. The message
# becomes the child's next user turn. Runs from any directory.
cmd_steer() {
  local fifo="" msg=""
  if (( $# == 1 )); then
    msg="$1"
  elif (( $# >= 2 )); then
    fifo="$1"; msg="$2"
  else
    die "steer: usage: cerebro steer [<pipe>] \"<message>\""
  fi
  [[ -n "$msg" ]] || die "steer: empty steering message"
  if [[ -z "$fifo" ]]; then
    local candidates=() f
    shopt -s nullglob
    for f in "$CEREBRO_HOME"/sessions/*/children/*.steer.fifo; do
      steer_fifo_live "$f" && candidates+=("$f")
    done
    shopt -u nullglob
    if (( ${#candidates[@]} == 0 )); then
      die "steer: no live paired session found. Start one with --pair (e.g. 'cerebro execute <repo> ... --pair'), then run 'cerebro steer \"<message>\"'."
    elif (( ${#candidates[@]} > 1 )); then
      { printf 'cerebro: steer: several live paired sessions -- pass the pipe of the one you mean:\n'
        for f in "${candidates[@]}"; do printf '  cerebro steer %s "<message>"\n' "$f"; done
      } >&2
      exit 1
    fi
    fifo="${candidates[0]}"
  fi
  [[ -p "$fifo" ]] || die "steer: no live paired session at $fifo (the child may have finished)"
  python3 -c "$PY_STEER_SEND" "$fifo" "$msg" || die "steer: could not deliver (the child may have finished)"
  say "cerebro: steered $(basename "${fifo%.steer.fifo}")"
}

