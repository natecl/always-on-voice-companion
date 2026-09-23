#!/usr/bin/env bash
# Play the known fixture into system audio, kill -9, relaunch so Recovery runs, grade P1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
# Only Grok proves P1. A stub session from the environment would grade as fail.
export CATCHER_ENGINE=grok
begin_harness_run "$SESSION" P1
launch_catcher "$SESSION" 1
sleep 2
require_fixture_play "$SESSION"
afplay "$ROOT/fixtures/known-60s.wav"
sleep 2
kill -9 "$(cat "$SESSION/catcher.pid")" || true
sleep 1
launch_catcher "$SESSION" 0
sleep 3
kill "$(cat "$SESSION/catcher.pid")" || true
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P1 --ref "$ROOT/fixtures/known-60s.ref.txt" --expect-recovery
