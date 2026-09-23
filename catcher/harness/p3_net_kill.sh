#!/usr/bin/env bash
# Block api.x.ai for 15s mid-session. Requires root and CATCHER_ALLOW_PF=1.
# The fixture loops the whole time so there is live speech before, during,
# and after the block. pf on/off wall times go into harness_run.json. After
# the rule clears the script waits for resumed on the system track, then
# keeps the session clock running until system:tail's horizon
# (resumed.atMs + backlogMs + margin + 20s - 5s) before it stops the app.
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
NEED="$(python3 - "$TARGET" "$ROOT/thresholds.json" "$ROOT" <<'PY'
import json, re, sys, time
from datetime import datetime

session, thresholds_path, root = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, root)
from grade import p3_system_tail_need_ms

thresholds = json.load(open(thresholds_path))
deadline = time.time() + thresholds["p3ResumeWithinMs"] / 1000


def session_started_ms(lines):
    for line in lines:
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("t") != "session":
            continue
        raw = row.get("startedAt")
        if not isinstance(raw, str):
            return None
        try:
            return int(datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp() * 1000)
        except ValueError:
            return None
    return None


found = None
while time.time() < deadline and found is None:
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
            gap_span = int(detail.get("toMs", 0)) - int(detail.get("fromMs", 0))
        # The heartbeat resumed (no backlog, before this gap) is not the chain.
        if (
            row.get("kind") == "resumed"
            and isinstance(detail, str)
            and "track=system" in detail
            and gap_span is not None
        ):
            match = re.search(r"backlogMs=(\d+)", detail)
            backlog = int(match.group(1)) if match else gap_span + int(thresholds["p3FallbackReplayMs"])
            found = (session_started_ms(lines), int(row.get("atMs", 0)), backlog)
            break
    if found is None:
        time.sleep(0.5)

if found is None:
    print(0)
    raise SystemExit(0)

started, resumed_at, backlog = found
need = p3_system_tail_need_ms(resumed_at, backlog, thresholds)
# Kill a second past the bar so the end stamp still satisfies end >= need.
target = need + 1000
if started is None:
    time.sleep(max(0, target - resumed_at) / 1000)
    print(need)
    raise SystemExit(0)

# Same map as grade.py's pf window: unix ms minus the session header.
# Cap the wait so a bad header cannot hang the gate.
cap = time.time() + 90
while time.time() < cap:
    session_now = int(time.time() * 1000) - started
    if session_now >= target:
        break
    time.sleep(0.25)
print(need)
PY
)"
if [[ "$NEED" == "0" ]]; then
  echo "No resumed track=system within the resume window. Stopping; the grade will say why." >&2
else
  echo "Session clock covered system:tail (need end >= ${NEED})."
fi
PID="$(cat "$SESSION/catcher.pid")"
kill "$PID" || true
# stopAfterLiveTail may still be holding the host clock. Grade after it exits
# so the end row is the post-hold stamp, not the pre-hold transcript.
for _ in $(seq 1 100); do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 0.25
done
cleanup
PLAYER=""
python3 "$ROOT/grade.py" --session "$TARGET" --gate P3
