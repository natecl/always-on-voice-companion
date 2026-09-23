#!/usr/bin/env bash
# Block api.x.ai for 15s mid-session. Requires root and CATCHER_ALLOW_PF=1.
# The fixture loops the whole time so there is live speech before, during,
# and after the block. pf on/off wall times go into harness_run.json. After
# the rule clears the script waits for the system resume grade.py will grade
# (the first gap ending at or after pfOn), then keeps recording until
# system:tail's horizon (resumed.atMs + backlogMs + margin + 20s - 5s).
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
echo "Network restored. Waiting for the system resume grade.py will grade."
TARGET="$(resolve_session "$SESSION")"
NEED="$(python3 - "$TARGET" "$ROOT" "$SESSION/harness_run.json" <<'PY'
import json, sys, time

session, root, run_path = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, root)
import grade

run = json.load(open(run_path, encoding="utf-8"))
t = grade.THRESHOLDS
# The grader times the resume by its backdated atMs (the gap end). The row is
# written after the post-resume final wait (GrokEngine.postResumeBudgetMs, 8s)
# and the new socket's handshake (5s), so a resume the grader accepts can land
# on disk up to ~13s after pfOff + p3ResumeWithinMs.
write_lag_s = 15
deadline = run["pfOffWallMs"] / 1000 + t["p3ResumeWithinMs"] / 1000 + write_lag_s


def read_rows():
    try:
        lines = open(f"{session}/events.jsonl", encoding="utf-8").read().splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


need = None
rows = []
while need is None and time.time() < deadline:
    rows = read_rows()
    need = grade.p3_harness_tail_need_ms(rows, run["pfOnWallMs"])
    if need is None:
        time.sleep(0.5)

if need is None:
    print(0)
    raise SystemExit(0)

# Keep recording, not only the clock, until a second past the bar: the live
# window after the backlog needs speech in it. Same wall map as the pf window.
started = grade.session_start_ms(rows)
target = need + 1000
cap = time.time() + 90
while time.time() < cap and int(time.time() * 1000) - started < target:
    time.sleep(0.25)
print(need)
PY
)"
if [[ "$NEED" == "0" ]]; then
  echo "No system resume for the pf block within the resume window. Stopping; the grade will say why." >&2
else
  echo "Recorded through system:tail (need end >= ${NEED})."
fi
PID="$(cat "$SESSION/catcher.pid")"
kill "$PID" || true
# stopAfterLiveTail keeps recording up to 30s when the signal lands before the
# floor. Grade after exit so the end row is the post-hold stamp.
for _ in $(seq 1 180); do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 0.25
done
cleanup
PLAYER=""
python3 "$ROOT/grade.py" --session "$TARGET" --gate P3
