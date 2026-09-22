#!/usr/bin/env bash
# Play the fixture and talk. Both tracks and a system-track speaker label must land.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
BIN="$(catcher_bin)"
export CATCHER_SESSION_ROOT="$SESSION"
export CATCHER_HARNESS=1
export CATCHER_ENGINE=grok
"$BIN" --auto-record &
echo $! > "$SESSION/catcher.pid"
echo "Speak into the mic while the fixture plays."
afplay "$ROOT/fixtures/known-60s.wav" &
sleep 20
wait || true
kill "$(cat "$SESSION/catcher.pid")" || true
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P6
