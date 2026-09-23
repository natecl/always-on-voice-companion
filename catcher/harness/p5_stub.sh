#!/usr/bin/env bash
# Same pipeline as P1 with CATCHER_ENGINE=stub. Optional second arg is a Grok session directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?stub session parent dir}"
REFERENCE="${2:-}"
mkdir -p "$SESSION"
export CATCHER_ENGINE=stub
begin_harness_run "$SESSION" P5
launch_catcher "$SESSION" 1
require_fixture_play "$SESSION"
afplay "$ROOT/fixtures/known-60s.wav"
sleep 2
# kill -9 leaves no end row. The relaunch runs Recovery, which writes ann + end
# — the same row types a recovered Grok session has. A plain kill does neither.
kill -9 "$(cat "$SESSION/catcher.pid")" || true
sleep 1
launch_catcher "$SESSION" 0
sleep 3
kill "$(cat "$SESSION/catcher.pid")" || true
TARGET="$(resolve_session "$SESSION")"
ARGS=(--session "$TARGET" --gate P5)
if [[ -n "$REFERENCE" ]]; then
  REF_DIR="$REFERENCE"
  if [[ ! -f "$REFERENCE/events.jsonl" ]]; then
    REF_DIR="$(resolve_session "$REFERENCE")"
  fi
  ARGS+=(--shape-reference "$REF_DIR")
fi
python3 "$ROOT/grade.py" "${ARGS[@]}"
