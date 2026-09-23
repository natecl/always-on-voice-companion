#!/usr/bin/env bash
# Usage: run_v1.sh b2 <session-dir>
#        run_v1.sh b4 <session-dir> cold-record
#
# S0 measurement harness. Not a phase verdict and not a v0 P-gate.
# warm-hotkey, warm-orb, and cold (orb) are refused until those inputs exist.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
GATE="${1:-}"
SESSION="${2:-}"
SCENARIO="${3:-}"
if [[ -z "$GATE" || -z "$SESSION" ]]; then
  echo "usage: $0 b2 <session-dir>" >&2
  echo "       $0 b4 <session-dir> cold-record" >&2
  exit 2
fi
mkdir -p "$SESSION"
case "$GATE" in
  b2) exec "$ROOT/b2_partials.sh" "$SESSION" ;;
  b4) exec "$ROOT/b4_start.sh" "$SESSION" ${SCENARIO:+"$SCENARIO"} ;;
  *)
    echo "unknown gate $GATE" >&2
    exit 2
    ;;
esac
