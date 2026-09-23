#!/usr/bin/env bash
# Play the known fixture into a harness auto-record session and grade B2.
# Numbers from this script are a baseline until a Mac grade_v1.json says pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

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

SESSION="${1:?session dir}"
mkdir -p "$SESSION"
export CATCHER_ENGINE=grok
begin_harness_run "$SESSION" B2
launch_catcher "$SESSION" 1
wait_for_mark "$SESSION" live 600 || {
  echo "B2: no live mark under $SESSION within 60s. The launch probe still runs before auto-record, so a slow grant check can eat this wait." >&2
  exit 1
}
sleep 2
append_harness_field "$SESSION" playWallMs "$(wall_ms)"
afplay "$ROOT/fixtures/known-60s.wav"
sleep 3
if [[ -s "$SESSION/catcher.pid" ]]; then
  kill "$(cat "$SESSION/catcher.pid")" 2>/dev/null || true
  for _ in $(seq 1 100); do
    if [[ ! -s "$SESSION/catcher.pid" ]] || ! kill -0 "$(cat "$SESSION/catcher.pid")" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
fi
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade_v1.py" --session "$TARGET" --gate B2 --fixture "$ROOT/fixtures/known-60s.wav"
