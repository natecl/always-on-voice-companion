#!/usr/bin/env bash
# Block api.x.ai for 15s mid-session. Requires CATCHER_ALLOW_PF=1.
# Every pfctl call is `sudo -n /sbin/pfctl` unless this process is already
# root, so a missing sudoers rule exits instead of asking for a password.
# /usr/local/bin/catcher-p3-gate is not used.
#
# The block is loaded into an anchor the main ruleset actually evaluates.
# Stock pf.conf evaluates anchor "com.apple/*", so that host uses
# com.apple/catcher. A main ruleset that is only `anchor "catcher"` uses
# that name. An empty ruleset gets /etc/pf.conf loaded for this run and
# flushed again on the way out. Anything else is left alone.
#
# tag=ok only after a mid-hold sample shows the block-drop rules dropped
# packets. A gap the rig never saw drops for is not a pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
if [[ "${CATCHER_ALLOW_PF:-}" != "1" ]]; then
  echo "Refusing to change the packet filter. Re-run with CATCHER_ALLOW_PF=1." >&2
  rig_obs_write "$SESSION" '{"tag":"pf-not-allowed","block":"pf-not-allowed"}'
  exit 2
fi
export CATCHER_ENGINE=grok
begin_harness_run "$SESSION" P3
RULE=""
PLAYER=""
PF_TOKEN=""
PF_LOADED_STOCK=0
ANCHOR="com.apple/catcher"
BLOCK_TAG=""
STEP="start"
export PFCTL_LOG="$SESSION/p3-pfctl.log"

write_obs() {
  local tag="$1"
  if [[ "$tag" == "ok" && -z "$BLOCK_TAG" ]]; then
    tag="died"
  fi
  python3 - "$SESSION" "$tag" "$ANCHOR" <<'PY'
import json, os, sys
from pathlib import Path
session, tag, anchor = sys.argv[1:]
root = Path(session)

def text(name, default=""):
    path = root / name
    if not path.is_file():
        return default
    return path.read_text(encoding="utf-8", errors="replace")

def lines(name):
    return [line.strip() for line in text(name).splitlines() if line.strip() and line.strip() != "n/a"]

samples = []
raw = text("p3-samples.json")
if raw.strip():
    try:
        samples = json.loads(raw)
    except json.JSONDecodeError:
        samples = []
killed = text("p3-states-killed.txt").strip()
left = text("p3-states-left.txt").strip()
record = {
    "tag": tag,
    "block": tag,
    "ruleset": text("p3-ruleset.txt").strip() or "not-observed",
    "anchor": text("p3-anchor.txt").strip() or anchor,
    "table": lines("p3-table-ips.txt"),
    "peers": lines("p3-lsof-peers.txt"),
    "statesKilled": int(killed) if killed.isdigit() else killed or "not-observed",
    "statesLeft": int(left) if left.isdigit() else left or "not-observed",
    "samples": samples,
}
path = root / "rig_obs.json"
tmp = path.with_suffix(".json.tmp")
tmp.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
tmp.replace(path)
PY
}

cleanup() {
  if [[ -n "$PLAYER" ]]; then
    kill "$PLAYER" 2>/dev/null || true
    pkill -P "$PLAYER" afplay 2>/dev/null || true
  fi
  pfctl_run -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  pfctl_run -a catcher -F all >/dev/null 2>&1 || true
  if [[ "$PF_LOADED_STOCK" == 1 ]]; then
    pfctl_run -F rules >/dev/null 2>&1 || true
    PF_LOADED_STOCK=0
  fi
  if [[ -n "$PF_TOKEN" ]]; then
    pfctl_run -X "$PF_TOKEN" >/dev/null 2>&1 || true
    PF_TOKEN=""
  fi
  if [[ -n "$RULE" ]]; then
    rm -f "$RULE"
  fi
  if [[ ! -s "$SESSION/rig_obs.json" ]]; then
    local tag="${BLOCK_TAG:-$STEP}"
    if [[ "$tag" == "ok" || -z "$tag" ]]; then
      tag="died"
    fi
    write_obs "$tag"
  fi
}
trap cleanup EXIT

note_sudo() {
  local out="$1"
  if printf '%s\n' "$out" | python3 "$ROOT/pf_obs.py" sudo-denied >/dev/null; then
    BLOCK_TAG="sudo-denied"
    return 0
  fi
  return 1
}

launch_catcher "$SESSION" 1
if ! play_fixture "$SESSION" --prepare; then
  exit 1
fi
(while play_fixture "$SESSION" --loop-guard; do :; done) &
PLAYER=$!
sleep 5
PID="$(cat "$SESSION/catcher.pid")"
STEP="peers"
lsof -nP -a -p "$PID" -iTCP:443 -sTCP:ESTABLISHED -Fn >"$SESSION/p3-lsof-tcp.txt" 2>>"$SESSION/p3-pfctl.log" || true
lsof -nP -a -p "$PID" -iUDP:443 -Fn >"$SESSION/p3-lsof-udp.txt" 2>>"$SESSION/p3-pfctl.log" || true
{
  dig +short api.x.ai A || true
  dig +short api.x.ai AAAA || true
} >"$SESSION/p3-dig.txt" || true
cat "$SESSION/p3-lsof-tcp.txt" "$SESSION/p3-lsof-udp.txt" | python3 "$ROOT/pf_obs.py" peers >"$SESSION/p3-endpoints.txt" || true
if [[ ! -s "$SESSION/p3-endpoints.txt" ]]; then
  printf '%s\n' "n/a" >"$SESSION/p3-lsof-peers.txt"
  BLOCK_TAG="no-live-peer"
  exit 1
fi
cp "$SESSION/p3-endpoints.txt" "$SESSION/p3-lsof-peers.txt"
python3 - "$ROOT" "$SESSION/p3-endpoints.txt" "$SESSION/p3-dig.txt" "$SESSION/p3-table-ips.txt" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import pf_obs
peers = []
for line in Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace").splitlines():
    parts = line.split()
    if len(parts) >= 2:
        peers.append((parts[0], parts[1]))
    elif len(parts) == 1:
        peers.append(("", parts[0]))
dig = pf_obs.dig_addresses(Path(sys.argv[3]).read_text(encoding="utf-8", errors="replace"))
seen = []
for _, remote in peers:
    if remote not in seen:
        seen.append(remote)
for addr in dig:
    if addr not in seen:
        seen.append(addr)
Path(sys.argv[4]).write_text("".join(f"{addr}\n" for addr in seen), encoding="utf-8")
PY

STEP="enable"
set +e
enable_out="$(pfctl_run -E)"
enable_status=$?
set -e
printf '%s\n' "$enable_out" >>"$SESSION/p3-pfctl.log"
if note_sudo "$enable_out"; then
  exit 1
fi
if [[ "$enable_status" -ne 0 ]]; then
  BLOCK_TAG="pf-enable-failed"
  exit 1
fi
PF_TOKEN="$(printf '%s\n' "$enable_out" | python3 "$ROOT/pf_obs.py" token)"
set +e
info_out="$(pfctl_run -s info)"
set -e
printf '%s\n' "$info_out" >>"$SESSION/p3-pfctl.log"
if ! printf '%s\n' "$info_out" | python3 "$ROOT/pf_obs.py" enabled >/dev/null; then
  BLOCK_TAG="pf-enable-failed"
  exit 1
fi

STEP="ruleset"
set +e
rules_out="$(pfctl_run -sr)"
rules_status=$?
set -e
printf '%s\n' "$rules_out" >"$SESSION/p3-main-rules.txt"
if note_sudo "$rules_out"; then
  exit 1
fi
if [[ "$rules_status" -ne 0 ]]; then
  BLOCK_TAG="pf-enable-failed"
  exit 1
fi
MAIN="$(printf '%s\n' "$rules_out" | python3 "$ROOT/pf_obs.py" classify)"
printf '%s\n' "$MAIN" >"$SESSION/p3-ruleset.txt"
case "$MAIN" in
  com.apple) ANCHOR="com.apple/catcher" ;;
  catcher) ANCHOR="catcher" ;;
  empty)
    set +e
    stock_out="$(pfctl_run -f /etc/pf.conf)"
    stock_status=$?
    set -e
    printf '%s\n' "$stock_out" >>"$SESSION/p3-pfctl.log"
    if [[ "$stock_status" -ne 0 ]]; then
      printf '%s\n' "none" >"$SESSION/p3-anchor.txt"
      BLOCK_TAG="ruleset-foreign"
      exit 1
    fi
    PF_LOADED_STOCK=1
    ANCHOR="com.apple/catcher"
    ;;
  *)
    printf '%s\n' "none" >"$SESSION/p3-anchor.txt"
    BLOCK_TAG="ruleset-foreign"
    exit 1
    ;;
esac
if [[ "${CATCHER_RIG_FAULT:-}" == "wrong-anchor" ]]; then
  ANCHOR="catcher-unevaluated"
fi
printf '%s\n' "$ANCHOR" >"$SESSION/p3-anchor.txt"

IPS="$(tr '\n' ' ' <"$SESSION/p3-table-ips.txt" | sed 's/  */ /g;s/^ //;s/ $//')"
RULE="$(mktemp)"
{
  echo "table <catcher_xai> { $IPS }"
  echo "block drop out quick proto { tcp udp } from any to <catcher_xai> port 443"
  echo "block drop in quick proto { tcp udp } from <catcher_xai> port 443 to any"
} > "$RULE"
STEP="load"
set +e
load_out="$(pfctl_run -a "$ANCHOR" -f "$RULE")"
load_status=$?
set -e
printf '%s\n' "$load_out" >>"$SESSION/p3-pfctl.log"
if note_sudo "$load_out"; then
  exit 1
fi
if [[ "$load_status" -ne 0 ]]; then
  BLOCK_TAG="rule-not-loaded"
  exit 1
fi
set +e
loaded="$(pfctl_run -a "$ANCHOR" -sr)"
table="$(pfctl_run -a "$ANCHOR" -t catcher_xai -T show)"
set -e
printf '%s\n' "$loaded" >"$SESSION/p3-anchor-rules.txt"
printf '%s\n' "$table" >"$SESSION/p3-table-show.txt"
if ! printf '%s\n' "$loaded" | python3 "$ROOT/pf_obs.py" blocks >/dev/null; then
  BLOCK_TAG="rule-not-loaded"
  exit 1
fi
if ! printf '%s\n' "$table" | python3 "$ROOT/pf_obs.py" table-covers "$SESSION/p3-table-ips.txt" >/dev/null; then
  BLOCK_TAG="rule-not-loaded"
  exit 1
fi
append_harness_field "$SESSION" pfOnWallMs "$(wall_ms)"
PF_ON="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pfOnWallMs"])' "$SESSION/harness_run.json")"

STEP="kill"
set +e
pfctl_run -s states >"$SESSION/p3-states-before.txt" || true
set -e
: >"$SESSION/p3-kill-raw.txt"
while read -r local remote; do
  [[ -z "${remote:-}" ]] && continue
  for pair in "$local $remote" "$remote $local"; do
    # shellcheck disable=SC2086
    set +e
    out="$(pfctl_run -k $pair)"
    status=$?
    set -e
    printf '%s\n' "$out" >>"$SESSION/p3-kill-raw.txt"
    if note_sudo "$out"; then
      exit 1
    fi
    if [[ "$status" -ne 0 ]]; then
      BLOCK_TAG="state-survived"
      exit 1
    fi
  done
done <"$SESSION/p3-endpoints.txt"
killed="$(python3 "$ROOT/pf_obs.py" killed <"$SESSION/p3-kill-raw.txt")"
printf '%s\n' "$killed" >"$SESSION/p3-states-killed.txt"
set +e
pfctl_run -s states >"$SESSION/p3-states-after.txt" || true
set -e
left_out="$(python3 "$ROOT/pf_obs.py" states-left "$SESSION/p3-table-ips.txt" <"$SESSION/p3-states-after.txt" || true)"
left_count="$(printf '%s\n' "$left_out" | head -n 1)"
printf '%s\n' "${left_count:-0}" >"$SESSION/p3-states-left.txt"
if [[ "${left_count:-0}" != "0" ]]; then
  BLOCK_TAG="state-survived"
  exit 1
fi

STEP="sample"
python3 -c 'import json,sys; print(" ".join(str(int(x)) for x in json.load(open(sys.argv[1]))["rigP3SampleMs"]))' "$ROOT/thresholds.json" >"$SESSION/p3-sample-offsets.txt"
: >"$SESSION/p3-samples.json"
python3 -c 'import json,sys; json.dump([], open(sys.argv[1],"w"))' "$SESSION/p3-samples.json"
first=1
while read -r offset; do
  target=$((PF_ON + offset))
  now="$(wall_ms)"
  if [[ "$now" -lt "$target" ]]; then
    python3 -c 'import sys,time; time.sleep(max(0, int(sys.argv[1]))/1000)' "$((target - now))"
  fi
  set +e
  rules_now="$(pfctl_run -a "$ANCHOR" -sr)"
  counters="$(pfctl_run -a "$ANCHOR" -vsr)"
  set -e
  printf '%s\n' "$rules_now" >"$SESSION/p3-anchor-rules.txt"
  printf '%s\n' "$counters" >"$SESSION/p3-anchor-counters.txt"
  lsof -nP -a -p "$PID" -iTCP:443 -sTCP:ESTABLISHED -Fn >"$SESSION/p3-sample-lsof.txt" 2>>"$SESSION/p3-pfctl.log" || true
  if ! printf '%s\n' "$rules_now" | python3 "$ROOT/pf_obs.py" blocks >/dev/null; then
    BLOCK_TAG="rules-vanished"
    exit 1
  fi
  python3 - "$ROOT" "$SESSION" "$offset" "$first" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import pf_obs
root = Path(sys.argv[2])
offset = int(sys.argv[3])
counters = (root / "p3-anchor-counters.txt").read_text(encoding="utf-8", errors="replace")
out_drops, in_drops = pf_obs.rule_counters(counters)
peers = [remote for _, remote in pf_obs.lsof_peers((root / "p3-sample-lsof.txt").read_text(encoding="utf-8", errors="replace"))]
table = [line.strip() for line in (root / "p3-table-ips.txt").read_text(encoding="utf-8").splitlines() if line.strip()]
leaked = [peer for peer in peers if peer not in table]
samples = json.loads((root / "p3-samples.json").read_text(encoding="utf-8"))
samples.append({
    "offsetMs": offset,
    "atWallMs": int(__import__("time").time() * 1000),
    "dropsOut": out_drops,
    "dropsIn": in_drops,
    "peers443": peers,
    "rulesPresent": True,
})
(root / "p3-samples.json").write_text(json.dumps(samples), encoding="utf-8")
if leaked:
    (root / "p3-peer-leak.txt").write_text("\n".join(leaked) + "\n", encoding="utf-8")
PY
  if [[ -s "$SESSION/p3-peer-leak.txt" ]]; then
    BLOCK_TAG="peer-leak"
    exit 1
  fi
  if [[ "$first" == 1 ]]; then
    drops="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s[-1]["dropsIn"]+s[-1]["dropsOut"])' "$SESSION/p3-samples.json")"
    if [[ "${drops:-0}" == "0" ]]; then
      BLOCK_TAG="no-drops"
      exit 1
    fi
    first=0
  fi
done <"$SESSION/p3-sample-offsets.txt"

BLOCK_TAG="ok"
write_obs ok

STEP="restore"
pfctl_run -a "$ANCHOR" -F rules >/dev/null 2>&1 || true
append_harness_field "$SESSION" pfOffWallMs "$(wall_ms)"
pfctl_run -a "$ANCHOR" -F all >/dev/null 2>&1 || true
echo "Network restored. Waiting for the system resume grade.py will grade."
TARGET="$(resolve_session "$SESSION")"
python3 - "$TARGET" "$ROOT" "$SESSION/harness_run.json" >"$SESSION/p3-need.txt" <<'PY'
import json, sys, time

session, root, run_path = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, root)
import grade

run = json.load(open(run_path, encoding="utf-8"))
t = grade.THRESHOLDS
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

started = grade.session_start_ms(rows)
target = need + 1000
cap = time.time() + 90
while time.time() < cap and int(time.time() * 1000) - started < target:
    time.sleep(0.25)
print(need)
PY
NEED="$(tr -d '[:space:]' <"$SESSION/p3-need.txt")"
if [[ "$NEED" == "0" ]]; then
  echo "No system resume for the pf block within the resume window. Stopping; the grade will say why." >&2
else
  echo "Recorded through system:tail (need end >= ${NEED})."
fi
stop_catcher "$SESSION" >/dev/null || true
cleanup
PLAYER=""
python3 "$ROOT/grade.py" --session "$TARGET" --gate P3
