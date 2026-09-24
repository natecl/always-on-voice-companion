#!/usr/bin/env bash
# Revoke Screen Recording mid-session. Requires CATCHER_ALLOW_TCC_RESET=1.
# Does not wait for a person to re-grant: the blocked annotation is polled,
# then the app is stopped. Restoring the grant is manual and is recorded.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
BUNDLE="${CATCHER_BUNDLE_ID:-com.catcher.app}"
mkdir -p "$SESSION"
if [[ "${CATCHER_ALLOW_TCC_RESET:-}" != "1" ]]; then
  echo "Refusing to reset TCC. Re-run with CATCHER_ALLOW_TCC_RESET=1. The grant has to be restored by hand afterwards." >&2
  echo "Command that will run: tccutil reset ScreenCapture $BUNDLE" >&2
  rig_obs_write "$SESSION" '{"tag":"tcc-not-allowed","regrantRequired":false}'
  exit 2
fi
export CATCHER_HARNESS=1
begin_harness_run "$SESSION" P2
launch_catcher "$SESSION" 1
wait_for_recording "$SESSION"
sleep 2
if [[ -s "$SESSION/live_session" ]]; then
  LIVE="$(cat "$SESSION/live_session")"
else
  LIVE="$(resolve_session "$SESSION")"
fi
printf '%s\n' "$LIVE" > "$SESSION/revoke_session"
wall_ms > "$SESSION/revoke_wall_ms"
append_harness_field "$SESSION" revokeWallMs "$(cat "$SESSION/revoke_wall_ms")"
set +e
tccutil reset ScreenCapture "$BUNDLE"
tcc_status=$?
set -e
blocked=1
if [[ "$tcc_status" -eq 0 ]]; then
  python3 - "$LIVE" <<'PY'
import json, sys, time
from pathlib import Path
path = Path(sys.argv[1]) / "events.jsonl"
deadline = time.time() + 10
while time.time() < deadline:
    if path.is_file():
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("t") == "ann" and row.get("kind") == "blocked":
                raise SystemExit(0)
    time.sleep(0.25)
raise SystemExit(1)
PY
  blocked=$?
fi
stop="$(stop_catcher "$SESSION")"
tag="ok"
if [[ "$tcc_status" -ne 0 ]]; then
  tag="tccutil-failed"
elif [[ "$blocked" -ne 0 ]]; then
  tag="blocked-not-observed"
fi
payload="$(python3 - "$tag" "$tcc_status" "$blocked" "$stop" <<'PY'
import json, sys
tag, tcc, blocked, stop = sys.argv[1:]
print(json.dumps({
    "tag": tag,
    "tccutilExit": int(tcc),
    "blockedObserved": blocked == "0",
    "regrantRequired": True,
    "stop": stop,
}))
PY
)"
rig_obs_write "$SESSION" "$payload"
TARGET="$(python3 "$ROOT/grade.py" --pick-revoke-session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P2 --revoke-at-ms "$(cat "$SESSION/revoke_wall_ms")"
