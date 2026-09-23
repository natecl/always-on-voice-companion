#!/usr/bin/env bash
# Play the fixture and talk. Both tracks and a system-track speaker label must land.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
export CATCHER_ENGINE=grok
begin_harness_run "$SESSION" P6
launch_catcher "$SESSION" 1
echo "Speak at normal conversational volume, at arm's length from the Mac, while the fixture plays."
afplay "$ROOT/fixtures/known-60s.wav" &
sleep 20
wait || true
kill "$(cat "$SESSION/catcher.pid")" || true
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P6
