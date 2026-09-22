#!/usr/bin/env bash
# Same pipeline as P1 with CATCHER_ENGINE=stub. Optional second arg is a Grok session directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?stub session parent dir}"
REFERENCE="${2:-}"
mkdir -p "$SESSION"
export CATCHER_ENGINE=stub
launch_catcher "$SESSION" 1
afplay "$ROOT/fixtures/known-60s.wav"
sleep 2
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
