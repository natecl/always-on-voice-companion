#!/usr/bin/env bash
# Mute output for the hold and restore it afterwards. Nothing reads stdin.
# noAudio must fire within 10s of capture start, from live frames.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
PRIOR=""
restore_volume() {
  if [[ "$PRIOR" == "true" ]]; then
    osascript -e 'set volume output muted true' >/dev/null 2>&1 || true
  elif [[ "$PRIOR" == "false" ]]; then
    osascript -e 'set volume output muted false' >/dev/null 2>&1 || true
  fi
}
trap restore_volume EXIT
if ! command -v osascript >/dev/null 2>&1; then
  rig_obs_write "$SESSION" '{"tag":"volume-not-observed","afplay":false}'
  exit 1
fi
PRIOR="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null || true)"
osascript -e 'set volume output muted true' >/dev/null
readback="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null || true)"
if [[ "$readback" != "true" ]]; then
  rig_obs_write "$SESSION" "$(python3 -c 'import json,sys; print(json.dumps({"tag":"mute-failed","readback":sys.argv[1],"afplay":False}))' "$readback")"
  exit 1
fi
begin_harness_run "$SESSION" P4
launch_catcher "$SESSION" 1
sleep 16
held="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null || true)"
stop="$(stop_catcher "$SESSION")"
tag="ok"
if [[ "$held" != "true" ]]; then
  tag="mute-lost"
fi
payload="$(python3 - "$tag" "$PRIOR" "$readback" "$held" "$stop" <<'PY'
import json, sys
tag, prior, readback, held, stop = sys.argv[1:]
print(json.dumps({
    "tag": tag,
    "mutedBefore": prior,
    "mutedReadback": readback,
    "mutedHeld": held,
    "afplay": False,
    "stop": stop,
}))
PY
)"
rig_obs_write "$SESSION" "$payload"
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P4
