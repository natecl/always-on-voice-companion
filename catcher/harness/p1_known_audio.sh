#!/usr/bin/env bash
# Play the known fixture into system audio, kill -9, relaunch so Recovery runs, grade P1.
# Audio starts only after the window probe prints RAISE OK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
export CATCHER_ENGINE=grok
begin_harness_run "$SESSION" P1
launch_catcher "$SESSION" 1
set +e
play_fixture "$SESSION"
play_status=$?
set -e
if [[ "$play_status" -ne 0 ]]; then
  stop_catcher "$SESSION" >/dev/null || true
  exit 1
fi
wall="$(sed -n 's/^wallMs=//p' "$SESSION/afplay_result.txt" | head -n 1)"
pid="$(tr -cd '0-9' < "$SESSION/catcher.pid")"
alive=0
if kill -0 "$pid" 2>/dev/null; then
  alive=1
fi
kill_hit=0
if [[ "$alive" -eq 1 ]] && kill -9 "$pid" 2>/dev/null; then
  kill_hit=1
fi
sleep 1
launch_catcher "$SESSION" 0
newpid="$(tr -cd '0-9' < "$SESSION/catcher.pid")"
stop="$(stop_catcher "$SESSION")"
payload="$(python3 - "$wall" "$alive" "$kill_hit" "$pid" "$newpid" "$stop" <<'PY'
import json, sys
wall, alive, hit, old, new, stop = sys.argv[1:]
died = alive != "1"
ok = (
    wall.isdigit() and int(wall) >= 55000
    and not died
    and hit == "1"
    and new.isdigit()
    and new != old
)
print(json.dumps({
    "tag": "ok" if ok else "premise-miss",
    "afplayExit": 0,
    "afplayWallMs": int(wall) if wall.isdigit() else None,
    "catcherAliveAfterFixture": not died,
    "catcherDiedDuringFixture": died,
    "kill9Hit": hit == "1",
    "killedPid": int(old) if old.isdigit() else None,
    "relaunchPid": int(new) if new.isdigit() else None,
    "stop": stop,
}))
PY
)"
rig_obs_write "$SESSION" "$payload"
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P1 --ref "$ROOT/fixtures/known-60s.ref.txt" --expect-recovery
