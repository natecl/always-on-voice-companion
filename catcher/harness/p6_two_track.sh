#!/usr/bin/env bash
# Play the fixture. The microphone hears it from the speakers; nobody has to
# talk, and nothing reads stdin. Both tracks and a system-track speaker label
# must land. Audio starts only when output is unmuted and the window is front.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
export CATCHER_ENGINE=grok
begin_harness_run "$SESSION" P6
settings="$(volume_line)"
volume="${settings#*volume=}"
volume="${volume%% *}"
muted="${settings#*muted=}"
if [[ "$muted" == "true" || "$volume" == "0" || "$volume" == "not-observed" ]]; then
  tag="output-muted"
  if [[ "$volume" == "0" ]]; then
    tag="volume-zero"
  fi
  if [[ "$volume" == "not-observed" || "$muted" == "not-observed" ]]; then
    tag="volume-not-observed"
  fi
  rig_obs_write "$SESSION" "$(python3 -c 'import json,sys; print(json.dumps({"tag": sys.argv[1], "volume": sys.argv[2]}))' "$tag" "$settings")"
  exit 1
fi
launch_catcher "$SESSION" 1
set +e
play_fixture "$SESSION"
play_status=$?
set -e
stop="$(stop_catcher "$SESSION")"
if [[ "$play_status" -ne 0 ]]; then
  exit 1
fi
wall="$(sed -n 's/^wallMs=//p' "$SESSION/afplay_result.txt" | head -n 1)"
payload="$(python3 - "$wall" "$stop" "$settings" <<'PY'
import json, sys
wall, stop, settings = sys.argv[1:]
print(json.dumps({
    "tag": "ok" if wall.isdigit() and int(wall) > 0 else "afplay-failed",
    "afplayExit": 0,
    "afplayWallMs": int(wall) if wall.isdigit() else None,
    "volume": settings,
    "stop": stop,
}))
PY
)"
rig_obs_write "$SESSION" "$payload"
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P6
