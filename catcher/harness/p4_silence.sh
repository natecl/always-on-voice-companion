#!/usr/bin/env bash
# Mute output and do not speak. noAudio must land within 10s of session start.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
echo "Mute system output and stay quiet, then press enter."
read -r _
BIN="$(catcher_bin)"
export CATCHER_SESSION_ROOT="$SESSION"
export CATCHER_HARNESS=1
"$BIN" --auto-record &
echo $! > "$SESSION/catcher.pid"
sleep 15
kill "$(cat "$SESSION/catcher.pid")" || true
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P4 --silence-at-ms 0
