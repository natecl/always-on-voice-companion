#!/usr/bin/env bash
# Usage: run.sh p1|p2|p3|p4|p5|p6 <session-dir> [extra]
# P5's extra argument is the Grok session dir used as the JSONL shape reference.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
GATE="${1:-}"
SESSION="${2:-}"
EXTRA="${3:-}"
if [[ -z "$GATE" || -z "$SESSION" ]]; then
  echo "usage: $0 p1|p2|p3|p4|p5|p6 <session-dir> [shape-reference-dir]" >&2
  exit 2
fi
mkdir -p "$SESSION"
case "$GATE" in
  p1) exec "$ROOT/p1_known_audio.sh" "$SESSION" ;;
  p2) exec "$ROOT/p2_tcc_revoke.sh" "$SESSION" ;;
  p3) exec "$ROOT/p3_net_kill.sh" "$SESSION" ;;
  p4) exec "$ROOT/p4_silence.sh" "$SESSION" ;;
  p5) exec "$ROOT/p5_stub.sh" "$SESSION" ${EXTRA:+"$EXTRA"} ;;
  p6) exec "$ROOT/p6_two_track.sh" "$SESSION" ;;
  *)
    echo "unknown gate $GATE" >&2
    exit 2
    ;;
esac
