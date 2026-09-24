#!/usr/bin/env bash
# Usage: run.sh p1|p2|p3|p4|p5|p6|preflight <session-dir> [extra]
#        run.sh board [--self-test] [--expect-sha SHA] [--expect-cdhash HEX] <parent-dir>
#        run.sh verdict <out-dir> --p1 <dir> --p2 <dir> ... --p6 <dir>
# P5's extra argument is the Grok session dir used as the JSONL shape reference.
# A non-zero gate prints TRACE lines from stages.log and keeps that exit status.
# `board` is the only command that writes a board. A gate refuses to start
# without a passing preflight of the same CDHash unless CATCHER_NO_PREFLIGHT=1,
# which marks the run not GREEN-eligible. Gates read no stdin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"
if [[ "${1:-}" == "board" ]]; then
  exec "$ROOT/board.sh" "${@:2}"
fi
GATE="${1:-}"
SESSION="${2:-}"
EXTRA="${3:-}"
if [[ -z "$GATE" || -z "$SESSION" ]]; then
  echo "usage: $0 p1|p2|p3|p4|p5|p6|preflight <session-dir> [shape-reference-dir]" >&2
  echo "       $0 board [--self-test] [--expect-sha SHA] [--expect-cdhash HEX] <parent-dir>" >&2
  echo "       $0 verdict <out-dir> --p1 <dir> --p2 <dir> --p3 <dir> --p4 <dir> --p5 <dir> --p6 <dir>" >&2
  exit 2
fi
mkdir -p "$SESSION"
export CATCHER_GATE="${CATCHER_GATE:-$GATE}"

run_gate() {
  require_preflight_pass "${CATCHER_PREFLIGHT_REPORT:-}" "${CATCHER_PREFLIGHT_CDHASH:-}"
  set +e
  "$@" </dev/null
  local status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    python3 "$ROOT/trace.py" "$SESSION" || true
  fi
  exit "$status"
}

case "$GATE" in
  preflight) exec "$ROOT/preflight.sh" "$SESSION" ;;
  verdict) exec python3 "$ROOT/verdict.py" --out "$SESSION" "${@:3}" ;;
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
