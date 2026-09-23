#!/usr/bin/env bash
# Block api.x.ai for 15s mid-session. Requires root and CATCHER_ALLOW_PF=1.
# The fixture loops the whole time so there is live speech before, during,
# and after the block. pf on/off wall times go into harness_run.json. After
# the rule clears the script waits for resumed on the system track, then
# keeps recording for backlogMs + the live tail before it stops the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
if [[ "${CATCHER_ALLOW_PF:-}" != "1" ]]; then
  echo "Refusing to change the packet filter. Re-run as root with CATCHER_ALLOW_PF=1." >&2
  exit 2
fi
export CATCHER_ENGINE=grok
begin_harness_run "$SESSION" P3
RULE=""
PLAYER=""
cleanup() {
  if [[ -n "$PLAYER" ]]; then
    kill "$PLAYER" 2>/dev/null || true
    pkill -P "$PLAYER" afplay 2>/dev/null || true
  fi
  pfctl -a catcher -F all >/dev/null 2>&1 || true
  if [[ -n "$RULE" ]]; then
    rm -f "$RULE"
  fi
}
trap cleanup EXIT
launch_catcher "$SESSION" 1
(while afplay "$ROOT/fixtures/known-60s.wav"; do :; done) &
PLAYER=$!
sleep 5
IPS="$(dig +short api.x.ai A | tr '\n' ' ')"
if [[ -z "$IPS" ]]; then
  echo "dig did not resolve api.x.ai" >&2
  exit 1
fi
RULE="$(mktemp)"
{
  echo "table <catcher_xai> { $IPS }"
  echo "block drop out proto tcp from any to <catcher_xai> port 443"
} > "$RULE"
pfctl -a catcher -f "$RULE"
append_harness_field "$SESSION" pfOnWallMs "$(wall_ms)"
sleep 15
pfctl -a catcher -F all || true
append_harness_field "$SESSION" pfOffWallMs "$(wall_ms)"
echo "Network restored. Waiting for resumed track=system (up to p3ResumeWithinMs)."
TARGET="$(resolve_session "$SESSION")"
WAIT_S="$(python3 - "$TARGET" "$ROOT/thresholds.json" <<'PY'
import json, re, sys, time
session, thresholds = sys.argv[1], json.load(open(sys.argv[2]))
deadline = time.time() + thresholds["p3ResumeWithinMs"] / 1000
tail = thresholds["p3MinTailMs"] + thresholds["p3LiveMarginMs"]
while time.time() < deadline:
    try:
        lines = open(f"{session}/events.jsonl", encoding="utf-8").read().splitlines()
    except OSError:
        lines = []
    gap_span = None
    for line in lines:
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        detail = row.get("detail")
        if row.get("kind") == "gap" and isinstance(detail, dict) and detail.get("track") == "system":
            gap_span = detail.get("toMs", 0) - detail.get("fromMs", 0)
        if row.get("kind") == "resumed" and isinstance(detail, str) and "track=system" in detail and gap_span is not None:
            match = re.search(r"backlogMs=(\d+)", detail)
            backlog = int(match.group(1)) if match else gap_span + thresholds["p3FallbackReplayMs"]
            print((backlog + tail) // 1000 + 1)
            raise SystemExit(0)
    time.sleep(0.5)
print(0)
PY
)"
if [[ "$WAIT_S" == "0" ]]; then
  echo "No resumed track=system within the resume window. Stopping; the grade will say why." >&2
else
  echo "Resumed. Recording ${WAIT_S}s more (backlog + live tail)."
  sleep "$WAIT_S"
fi
kill "$(cat "$SESSION/catcher.pid")" || true
sleep 1
cleanup
PLAYER=""
python3 "$ROOT/grade.py" --session "$TARGET" --gate P3
