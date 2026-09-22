#!/usr/bin/env bash
# Usage: run.sh p1|p2|p3|p4|p5|p6|preflight <session-dir> [extra]
# P5's extra argument is the Grok session dir used as the JSONL shape reference.
# A non-zero gate prints TRACE lines from stages.log and keeps that exit status.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
GATE="${1:-}"
SESSION="${2:-}"
EXTRA="${3:-}"
if [[ -z "$GATE" || -z "$SESSION" ]]; then
  echo "usage: $0 p1|p2|p3|p4|p5|p6|preflight <session-dir> [shape-reference-dir]" >&2
  exit 2
fi
mkdir -p "$SESSION"

run_gate() {
  set +e
  "$@"
  local status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    python3 "$ROOT/trace.py" "$SESSION" || true
  fi
  exit "$status"
}

case "$GATE" in
  preflight) exec "$ROOT/preflight.sh" "$SESSION" ;;
  p1) run_gate "$ROOT/p1_known_audio.sh" "$SESSION" ;;
  p2) run_gate "$ROOT/p2_tcc_revoke.sh" "$SESSION" ;;
  p3) run_gate "$ROOT/p3_net_kill.sh" "$SESSION" ;;
  p4) run_gate "$ROOT/p4_silence.sh" "$SESSION" ;;
  p5) run_gate "$ROOT/p5_stub.sh" "$SESSION" ${EXTRA:+"$EXTRA"} ;;
  p6) run_gate "$ROOT/p6_two_track.sh" "$SESSION" ;;
  *)
    echo "unknown gate $GATE" >&2
    exit 2
    ;;
esac
