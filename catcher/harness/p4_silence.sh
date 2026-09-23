#!/usr/bin/env bash
# Mute output and do not speak. noAudio must fire within 10s of capture start,
# from live frames (both PCM files), with its emission time on the ann.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
echo "Mute system output and stay quiet, then press enter."
read -r _
begin_harness_run "$SESSION" P4
launch_catcher "$SESSION" 1
# >= 10 s of PCM after capture start plus emission slack.
sleep 16
kill "$(cat "$SESSION/catcher.pid")" || true
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P4
