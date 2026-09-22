#!/usr/bin/env bash
# Play the known fixture into system audio, kill -9, relaunch so Recovery runs, grade P1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
BIN="$(catcher_bin)"
export CATCHER_SESSION_ROOT="$SESSION"
export CATCHER_HARNESS=1
export CATCHER_ENGINE="${CATCHER_ENGINE:-grok}"
"$BIN" --auto-record &
echo $! > "$SESSION/catcher.pid"
sleep 2
afplay "$ROOT/fixtures/known-60s.wav"
sleep 2
kill -9 "$(cat "$SESSION/catcher.pid")" || true
sleep 1
"$BIN" &
echo $! > "$SESSION/catcher.pid"
sleep 3
kill "$(cat "$SESSION/catcher.pid")" || true
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P1 --ref "$ROOT/fixtures/known-60s.ref.txt" --expect-recovery
