#!/usr/bin/env bash
# Revoke Screen Recording mid-session. Requires CATCHER_ALLOW_TCC_RESET=1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
BUNDLE="${CATCHER_BUNDLE_ID:-com.catcher.app}"
mkdir -p "$SESSION"
if [[ "${CATCHER_ALLOW_TCC_RESET:-}" != "1" ]]; then
  echo "Refusing to reset TCC. Re-run with CATCHER_ALLOW_TCC_RESET=1 while you are ready to re-grant." >&2
  echo "Command that will run: tccutil reset ScreenCapture $BUNDLE" >&2
  exit 2
fi
export CATCHER_HARNESS=1
launch_catcher "$SESSION" 1
wait_for_recording "$SESSION"
# Mid-session, not at t=0. Pin the directory before tccutil: a later
# startCapture failure writes a newer events.jsonl that must not be graded.
sleep 2
if [[ -s "$SESSION/live_session" ]]; then
  LIVE="$(cat "$SESSION/live_session")"
else
  LIVE="$(resolve_session "$SESSION")"
fi
printf '%s\n' "$LIVE" > "$SESSION/revoke_session"
python3 - <<'PY' > "$SESSION/revoke_wall_ms"
import time
print(int(time.time() * 1000))
PY
tccutil reset ScreenCapture "$BUNDLE"
echo "TCC reset at wall ms $(cat "$SESSION/revoke_wall_ms")."
echo "Re-grant Screen & System Audio Recording for ${BUNDLE}, then press enter."
read -r _
kill "$(cat "$SESSION/catcher.pid")" || true
TARGET="$(python3 "$ROOT/grade.py" --pick-revoke-session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P2 --revoke-at-ms "$(cat "$SESSION/revoke_wall_ms")"
