#!/usr/bin/env bash
# Block api.x.ai for 15s mid-session. Requires CATCHER_ALLOW_PF=1.
# Every pfctl call is `sudo -n /sbin/pfctl` so NOPASSWD matches the absolute
# path and a missing sudoers rule fails closed (no password prompt). That
# wrap is required when this script is not root. Preferred Mac invoke is a
# root session, after which these same calls run as root:
#   sudo -n env CATCHER_APP=… CATCHER_ALLOW_PF=1 … run.sh p3 <session>
# Nathan installs /usr/local/bin/catcher-p3-gate and /etc/sudoers.d/catcher-p3
# with NOPASSWD for /sbin/pfctl and that gate only:
#   n.chinlue ALL=(root) NOPASSWD: /sbin/pfctl
#   n.chinlue ALL=(root) NOPASSWD: /usr/local/bin/catcher-p3-gate
# /usr/bin/env is not a sudoers command.
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
  echo "Refusing to change the packet filter. Re-run with CATCHER_ALLOW_PF=1." >&2
  exit 2
fi
export CATCHER_ENGINE=grok
begin_harness_run "$SESSION" P3
RULE=""
PLAYER=""
PF_TOKEN=""
# Stock /etc/pf.conf evaluates anchor "com.apple/*" only. A top-level
# "catcher" anchor is loaded and then ignored: -k drops the live socket,
# the next connect succeeds, and the graded gap is the ~1s reconnect.
ANCHOR="com.apple/catcher"
cleanup() {
  if [[ -n "$PLAYER" ]]; then
    kill "$PLAYER" 2>/dev/null || true
    pkill -P "$PLAYER" afplay 2>/dev/null || true
  fi
  sudo -n /sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  sudo -n /sbin/pfctl -a catcher -F all >/dev/null 2>&1 || true
  if [[ -n "$PF_TOKEN" ]]; then
    sudo -n /sbin/pfctl -X "$PF_TOKEN" >/dev/null 2>&1 || true
    PF_TOKEN=""
  fi
  if [[ -n "$RULE" ]]; then
    rm -f "$RULE"
  fi
}
trap cleanup EXIT
launch_catcher "$SESSION" 1
require_fixture_play "$SESSION"
(while afplay "$ROOT/fixtures/known-60s.wav"; do :; done) &
PLAYER=$!
sleep 5
PID="$(cat "$SESSION/catcher.pid")"
# The graded socket is the one Catcher already has open, not whatever
# `dig api.x.ai` returns. That name is Cloudflare (104.18.0.0/15). The STT
# stream's peer is Deepgram (api.deepgram.com, a different address), so a
# table built from api.x.ai never matches the live packets. Partial text and
# ~32 kB/s then continue for the whole block.
# lsof is the peer that is actually connected. TCP and UDP both: a QUIC
# socket is UDP and `-iTCP` does not list it. dig of both names only covers
# a reconnect to a published address.
lsof -nP -a -p "$PID" -iTCP:443 -Fn >"$SESSION/p3-lsof-tcp.txt" 2>"$SESSION/p3-lsof.err" || true
lsof -nP -a -p "$PID" -iUDP:443 -Fn >"$SESSION/p3-lsof-udp.txt" 2>>"$SESSION/p3-lsof.err" || true
{
  dig +short api.x.ai A || true
  dig +short api.x.ai AAAA || true
  dig +short api.deepgram.com A || true
  dig +short api.deepgram.com AAAA || true
} >"$SESSION/p3-dig.txt" || true
python3 - "$SESSION" "$SESSION/p3-lsof-tcp.txt" "$SESSION/p3-lsof-udp.txt" "$SESSION/p3-dig.txt" <<'PEERS'
import ipaddress
import sys
from pathlib import Path

session = Path(sys.argv[1])

def read(path):
    file = Path(path)
    if not file.is_file():
        return ""
    return file.read_text(encoding="utf-8", errors="replace")

def normalize(raw):
    text = raw.strip().strip("[]")
    if "%" in text:
        text = text.split("%", 1)[0]
    if text.startswith("::ffff:"):
        text = text[7:]
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return None
    mapped = getattr(addr, "ipv4_mapped", None)
    if mapped is not None:
        return str(mapped)
    return str(addr)

def split_endpoint(token):
    token = token.strip()
    if not token or token.startswith("*"):
        return None, None
    if token.startswith("["):
        host, _, rest = token[1:].partition("]")
        port = rest[1:] if rest.startswith(":") else ""
        return normalize(host), port
    if token.count(":") == 1 and token.split(":", 1)[0].count(".") == 3:
        host, port = token.split(":", 1)
        return normalize(host), port
    host, sep, port = token.rpartition(":")
    if not sep:
        return None, None
    return normalize(host), port

pairs = []
seen = set()
blob = read(sys.argv[2]) + "\n" + read(sys.argv[3])
for line in blob.splitlines():
    if not line.startswith("n") or "->" not in line:
        continue
    left, right = line[1:].split("->", 1)
    local, _ = split_endpoint(left)
    remote, port = split_endpoint(right)
    if remote is None or port not in ("443", "https"):
        continue
    key = (local or "", remote)
    if key in seen:
        continue
    seen.add(key)
    pairs.append(key)

table = []
table_seen = set()

def add(ip):
    if ip and ip not in table_seen:
        table_seen.add(ip)
        table.append(ip)

for _, remote in pairs:
    add(remote)
for line in read(sys.argv[4]).splitlines():
    add(normalize(line.strip().rstrip(".")))

(session / "p3-endpoints.txt").write_text(
    "".join(f"{local} {remote}\n" for local, remote in pairs),
    encoding="utf-8",
)
(session / "p3-table-ips.txt").write_text(
    "".join(f"{ip}\n" for ip in table),
    encoding="utf-8",
)
if not pairs:
    sys.stderr.write(
        "No :443 peer on the Catcher pid. dig(api.x.ai) does not name the live socket.\n"
    )
    sys.exit(1)
PEERS
IPS="$(tr '\n' ' ' <"$SESSION/p3-table-ips.txt" | sed 's/  */ /g;s/^ //;s/ $//')"
if [[ -z "$IPS" ]]; then
  echo "No address for the live STT socket or api.x.ai / api.deepgram.com" >&2
  exit 1
fi
RULE="$(mktemp)"
# Both directions. With only outbound dropped, server frames already in
# flight kept landing after pfOn and pushed the engine's inbound-stall clock
# (and so degraded and the gap start) seconds past the block start.
{
  echo "table <catcher_xai> { $IPS }"
  echo "block drop out quick proto { tcp udp } from any to <catcher_xai> port 443"
  echo "block drop in quick proto { tcp udp } from <catcher_xai> port 443 to any"
} > "$RULE"
# -E reference-counts. Releasing the token in cleanup does not turn pf off
# if the host already had it enabled.
enable_out="$(sudo -n /sbin/pfctl -E 2>&1)" || {
  echo "pfctl -E failed: $enable_out" >&2
  exit 1
}
PF_TOKEN="$(printf '%s\n' "$enable_out" | sed -n 's/.*Token *: *//p' | head -n 1)"
sudo -n /sbin/pfctl -a "$ANCHOR" -f "$RULE"
append_harness_field "$SESSION" pfOnWallMs "$(wall_ms)"
# pf passes a packet that matches an existing state without reading the rule.
# Kill those states and wait before the hold. A background -k let the socket
# die and reconnect while this script still called the block "on".
# Darwin does not treat a wildcard source as "any" for -k, so that form kills
# nothing and the established socket keeps passing. Kill the concrete pair,
# both directions, from the process sockets and from the state table.
sudo -n /sbin/pfctl -s states >"$SESSION/p3-states-before.txt" 2>>"$SESSION/p3-pf-kill.txt" || true
python3 - "$SESSION/p3-states-before.txt" "$SESSION/p3-table-ips.txt" >"$SESSION/p3-state-pairs.txt" <<'STATES'
import ipaddress
import re
import sys
from pathlib import Path

def normalize(raw):
    text = raw.strip().strip("[]")
    if "%" in text:
        text = text.split("%", 1)[0]
    if text.startswith("::ffff:"):
        text = text[7:]
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return None
    mapped = getattr(addr, "ipv4_mapped", None)
    return str(mapped or addr)

table = set()
for line in Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace").splitlines():
    ip = normalize(line.strip())
    if ip:
        table.add(ip)

endpoint = re.compile(
    r"(?:\[([0-9A-Fa-f:.%]+)\]|(\d{1,3}(?:\.\d{1,3}){3}))[:.](\d+)"
)
emitted = set()
for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    found = []
    for match in endpoint.finditer(line):
        ip = normalize(match.group(1) or match.group(2))
        if ip:
            found.append((ip, match.group(3)))
    if "443" not in {port for _, port in found}:
        continue
    blocked = [ip for ip, _ in found if ip in table]
    others = [ip for ip, _ in found if ip not in table]
    for remote in blocked:
        for local in others:
            key = (local, remote)
            if key in emitted:
                continue
            emitted.add(key)
            sys.stdout.write(f"{local} {remote}\n")
STATES
: >"$SESSION/p3-pf-kill.txt"
kill_pair() {
  local src="$1" dst="$2" out
  if [[ -z "$src" || -z "$dst" ]]; then
    return 0
  fi
  if ! out="$(sudo -n /sbin/pfctl -k "$src" -k "$dst" 2>&1)"; then
    printf '%s\n' "$out" | tee -a "$SESSION/p3-pf-kill.txt" >&2
    exit 1
  fi
  printf '%s\n' "$out" >>"$SESSION/p3-pf-kill.txt"
}
while read -r src dst; do
  kill_pair "$src" "$dst"
  kill_pair "$dst" "$src"
done <"$SESSION/p3-endpoints.txt"
while read -r src dst; do
  kill_pair "$src" "$dst"
  kill_pair "$dst" "$src"
done <"$SESSION/p3-state-pairs.txt"
sudo -n /sbin/pfctl -s states >"$SESSION/p3-states-after.txt" 2>>"$SESSION/p3-pf-kill.txt" || true
# Only the process's own peers must be gone. A published Cloudflare address
# can still have some other app's state; that state is not this socket.
if ! python3 - "$SESSION/p3-states-after.txt" "$SESSION/p3-endpoints.txt" <<'STILL'
import ipaddress
import re
import sys
from pathlib import Path

def normalize(raw):
    text = raw.strip().strip("[]")
    if "%" in text:
        text = text.split("%", 1)[0]
    if text.startswith("::ffff:"):
        text = text[7:]
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return None
    mapped = getattr(addr, "ipv4_mapped", None)
    return str(mapped or addr)

peers = set()
for line in Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace").splitlines():
    parts = line.split()
    if not parts:
        continue
    ip = normalize(parts[-1])
    if ip:
        peers.add(ip)
endpoint = re.compile(
    r"(?:\[([0-9A-Fa-f:.%]+)\]|(\d{1,3}(?:\.\d{1,3}){3}))[:.](\d+)"
)
for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    hit = False
    port443 = False
    for match in endpoint.finditer(line):
        ip = normalize(match.group(1) or match.group(2))
        if match.group(3) == "443":
            port443 = True
        if ip in peers:
            hit = True
    if hit and port443:
        sys.stderr.write(line + "\n")
        sys.exit(1)
STILL
then
  echo "The live :443 state is still installed, so packets would skip the new rule." >&2
  exit 1
fi
# 15s after the states are gone. The engine's inbound stall is 5s, so the
# hole that remains still spans the 10s grade bar and reaches pf off.
sleep 15
# Rules first, then stamp: -F all clears rules before its slower steps, so a
# stamp after it lands seconds after traffic can flow again.
sudo -n /sbin/pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1 || true
append_harness_field "$SESSION" pfOffWallMs "$(wall_ms)"
sudo -n /sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
echo "Network restored. Waiting for the system resume grade.py will grade."
TARGET="$(resolve_session "$SESSION")"
# The heredoc must not sit inside "$(...)". macOS bash 3.2 parses that as an
# open quote, and the apostrophe in the Python comment is then unexpected EOF.
python3 - "$TARGET" "$ROOT" "$SESSION/harness_run.json" >"$SESSION/p3-need.txt" <<'PY'
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
NEED="$(tr -d '[:space:]' <"$SESSION/p3-need.txt")"
if [[ "$NEED" == "0" ]]; then
  echo "No system resume for the pf block within the resume window. Stopping; the grade will say why." >&2
else
  echo "Recorded through system:tail (need end >= ${NEED})."
fi
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
