#!/usr/bin/env bash
# B4 cold baseline: process not running, grants already in place, then launch
# plus one Record click. warm-hotkey, warm-orb, and cold (orb) are later slices.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

wait_for_file() {
  local path="$1"
  local limit="$2"
  local waited=0
  while [[ ! -s "$path" && "$waited" -lt "$limit" ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [[ -s "$path" ]]
}

wait_for_mark() {
  local root="$1"
  local name="$2"
  local limit="$3"
  local waited=0
  while [[ "$waited" -lt "$limit" ]]; do
    if python3 - "$root" "$name" <<'PY'
import json, os, sys
root, name = sys.argv[1], sys.argv[2]
for dirpath, _, files in os.walk(root):
    if "latency.jsonl" not in files:
        continue
    for line in open(os.path.join(dirpath, "latency.jsonl"), encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("t") == "mark" and row.get("name") == name:
            raise SystemExit(0)
raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

input_bin() {
  local src="$ROOT/input_events.swift"
  local bin="${TMPDIR:-/tmp}/catcher-input-events"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    if ! swiftc -O -framework CoreGraphics -o "$bin" "$src"; then
      echo "Cannot compile $src. B4's click is a CGEvent and needs the macOS SDK." >&2
      return 1
    fi
  fi
  echo "$bin"
}

record_b4_run() {
  local root="$1"
  local launch_ms="$2"
  local click_ms="$3"
  local stop_ms="$4"
  local sockets="$5"
  python3 - "$root/harness_run.json" "$launch_ms" "$click_ms" "$stop_ms" "$sockets" <<'PY'
import json, sys
path, launch_ms, click_ms, stop_ms, sockets = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    record = json.load(handle)
record["inputs"] = [
    {"kind": "launch", "wallMs": int(launch_ms)},
    {"kind": "recordButton", "wallMs": int(click_ms)},
    {"kind": "recordButton", "wallMs": int(stop_ms)},
]
record["idleSocketLines"] = [line for line in open(sockets, encoding="utf-8", errors="replace").read().splitlines() if line.strip()]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
PY
}

SESSION="${1:?session dir}"
SCENARIO="${2:-}"
case "$SCENARIO" in
  cold-record) ;;
  warm-hotkey|warm-orb|cold)
    echo "S0 records cold-record only. $SCENARIO waits on a later slice (hotkey ST2, orb ST3, resident cold ST4)." >&2
    exit 2
    ;;
  *)
    echo "usage: b4_start.sh <session-dir> cold-record" >&2
    exit 2
    ;;
esac

if pgrep -x CatcherApp >/dev/null 2>&1; then
  echo "CatcherApp is already running. Quit it before a cold-record run so t0 is a real launch." >&2
  exit 2
fi

mkdir -p "$SESSION"
export CATCHER_ENGINE=grok
begin_harness_run "$SESSION" B4-cold-record
LAUNCH_MS="$(wall_ms)"
launch_catcher "$SESSION" 0
FRAME="$SESSION/record_button_frame.json"
wait_for_file "$SESSION/ui_ready" 600 || {
  echo "B4: Catcher did not finish launch (no ui_ready) within 60s." >&2
  exit 1
}
wait_for_file "$FRAME" 50 || {
  echo "B4: Record button frame was not written. The window may be offscreen." >&2
  exit 1
}
PID="$(cat "$SESSION/catcher.pid")"
SOCKETS="$SESSION/idle_sockets.txt"
lsof -nP -iTCP -a -p "$PID" >"$SOCKETS" 2>/dev/null || true
CLICK_MS="$(wall_ms)"
"$(input_bin)" click-frame "$FRAME"
wait_for_mark "$SESSION" live 150 || {
  echo "B4: no live mark within 15s of launch. Grade will record the miss." >&2
}
afplay "$ROOT/fixtures/known-60s.wav" &
PLAY_PID=$!
sleep 8
kill "$PLAY_PID" 2>/dev/null || true
wait "$PLAY_PID" 2>/dev/null || true
STOP_MS="$(wall_ms)"
if [[ -s "$FRAME" ]]; then
  "$(input_bin)" click-frame "$FRAME" || true
fi
wait_for_mark "$SESSION" ended 100 || true
if [[ -s "$SESSION/catcher.pid" ]] && kill -0 "$(cat "$SESSION/catcher.pid")" 2>/dev/null; then
  kill "$(cat "$SESSION/catcher.pid")" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$(cat "$SESSION/catcher.pid")" 2>/dev/null || break
    sleep 0.1
  done
fi
record_b4_run "$SESSION" "$LAUNCH_MS" "$CLICK_MS" "$STOP_MS" "$SOCKETS"
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade_v1.py" --session "$TARGET" --gate B4 --scenario cold-record
