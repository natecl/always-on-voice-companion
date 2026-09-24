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
# 1 only when this run loaded /etc/pf.conf into an empty main ruleset.
# Cleanup then flushes that main ruleset and leaves the host empty again.
PF_LOADED_STOCK=0
# The block has to land in an anchor the main ruleset actually evaluates.
# Stock /etc/pf.conf evaluates anchor "com.apple/*", so that host uses
# com.apple/catcher. A main ruleset that is only `anchor "catcher"` never
# reaches that path; this run then loads the same rules into `catcher`.
# Anything with neither hook is left alone.
ANCHOR="com.apple/catcher"
# OBS_START
# Session files below survive cleanup. The block tag is one of
# pf-anchor-unreachable, NOT_EFFECTIVE, kill-miss, or ok.
seal_obs_files() {
  [[ -f "$SESSION/p3-ruleset.txt" ]] || printf '%s\n' "n/a" >"$SESSION/p3-ruleset.txt"
  [[ -f "$SESSION/p3-anchor.txt" ]] || printf '%s\n' "n/a" >"$SESSION/p3-anchor.txt"
  [[ -f "$SESSION/p3-main-rules.txt" ]] || printf '%s\n' "n/a" >"$SESSION/p3-main-rules.txt"
  [[ -f "$SESSION/p3-lsof-peers.txt" ]] || printf '%s\n' "n/a" >"$SESSION/p3-lsof-peers.txt"
  [[ -f "$SESSION/p3-kill-counts.txt" ]] || printf '%s\n' "states_killed=n/a" >"$SESSION/p3-kill-counts.txt"
  [[ -f "$SESSION/p3-out-packets.txt" ]] || printf '%s\n' "Packets:n/a" >"$SESSION/p3-out-packets.txt"
}

write_block_tag() {
  local tag="$1" ruleset anchor packets kills
  case "$tag" in
    pf-anchor-unreachable|NOT_EFFECTIVE|kill-miss|ok) ;;
    *)
      echo "bad block tag: $tag" >&2
      tag="pf-anchor-unreachable"
      ;;
  esac
  seal_obs_files
  printf '%s\n' "$tag" >"$SESSION/p3-block.txt"
  ruleset="$(tr -d '[:space:]' <"$SESSION/p3-ruleset.txt")"
  anchor="$(tr -d '[:space:]' <"$SESSION/p3-anchor.txt")"
  packets="$(tr -d '[:space:]' <"$SESSION/p3-out-packets.txt")"
  kills="$(head -n 1 "$SESSION/p3-kill-counts.txt" | tr -d '[:space:]')"
  {
    printf 'ruleset=%s\n' "$ruleset"
    printf 'anchor=%s\n' "$anchor"
    printf 'sr=p3-main-rules.txt\n'
    printf 'peers=p3-lsof-peers.txt\n'
    printf 'kills=p3-kill-counts.txt\n'
    printf 'packets=%s\n' "$packets"
    printf 'block=%s\n' "$tag"
  } >"$SESSION/p3-obs.txt"
  echo "p3 block=$tag ruleset=$ruleset anchor=$anchor packets=$packets" >&2
}

summarize_kills() {
  python3 - "$SESSION/p3-kill-counts.txt" >"$SESSION/p3-kill-counts.next" <<'KCOUNTS'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
total = 0
for line in text.splitlines():
    if line.startswith("states_killed="):
        continue
    match = re.search(r"killed\s+(\d+)\s+states", line)
    if match:
        total += int(match.group(1))
raw = "\n".join(
    line for line in text.splitlines() if not line.startswith("states_killed=")
)
if not raw.strip():
    sys.stdout.write("states_killed=n/a\n")
else:
    if not raw.endswith("\n"):
        raw += "\n"
    sys.stdout.write(f"states_killed={total}\n{raw}")
KCOUNTS
  mv "$SESSION/p3-kill-counts.next" "$SESSION/p3-kill-counts.txt"
}
# OBS_END
cleanup() {
  if [[ -n "$PLAYER" ]]; then
    kill "$PLAYER" 2>/dev/null || true
    pkill -P "$PLAYER" afplay 2>/dev/null || true
  fi
  sudo -n /sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  sudo -n /sbin/pfctl -a catcher -F all >/dev/null 2>&1 || true
  if [[ "$PF_LOADED_STOCK" == 1 ]]; then
    sudo -n /sbin/pfctl -F rules >/dev/null 2>&1 || true
    PF_LOADED_STOCK=0
  fi
  if [[ -n "$PF_TOKEN" ]]; then
    sudo -n /sbin/pfctl -X "$PF_TOKEN" >/dev/null 2>&1 || true
    PF_TOKEN=""
  fi
  if [[ -n "$RULE" ]]; then
    rm -f "$RULE"
  fi
  # pf is flushed above. The p3-* session files stay for the scoreboard.
  if [[ ! -s "$SESSION/p3-block.txt" ]]; then
    write_block_tag pf-anchor-unreachable
  fi
}
trap cleanup EXIT
launch_catcher "$SESSION" 1
require_fixture_play "$SESSION"
(while afplay "$ROOT/fixtures/known-60s.wav"; do :; done) &
PLAYER=$!
sleep 5
PID="$(cat "$SESSION/catcher.pid")"
# lsof is the peer that is actually connected. TCP and UDP both: a QUIC
# socket is UDP and `-iTCP` does not list it. dig of api.x.ai only covers a
# reconnect to a published address. The live socket is already one of those.
lsof -nP -a -p "$PID" -iTCP:443 -Fn >"$SESSION/p3-lsof-tcp.txt" 2>"$SESSION/p3-lsof.err" || true
lsof -nP -a -p "$PID" -iUDP:443 -Fn >"$SESSION/p3-lsof-udp.txt" 2>>"$SESSION/p3-lsof.err" || true
{
  dig +short api.x.ai A || true
  dig +short api.x.ai AAAA || true
} >"$SESSION/p3-dig.txt" || true
if ! python3 - "$SESSION" "$SESSION/p3-lsof-tcp.txt" "$SESSION/p3-lsof-udp.txt" "$SESSION/p3-dig.txt" <<'PEERS'
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
then
  peer_fail=1
else
  peer_fail=0
fi
if [[ -f "$SESSION/p3-endpoints.txt" ]]; then
  cp "$SESSION/p3-endpoints.txt" "$SESSION/p3-lsof-peers.txt"
else
  printf '%s\n' "n/a" >"$SESSION/p3-lsof-peers.txt"
fi
if [[ -f "$SESSION/p3-table-ips.txt" ]]; then
  IPS="$(tr '\n' ' ' <"$SESSION/p3-table-ips.txt" | sed 's/  */ /g;s/^ //;s/ $//')"
else
  IPS=""
fi
if [[ "$peer_fail" -ne 0 || -z "$IPS" ]]; then
  echo "No address for the live STT socket or api.x.ai" >&2
  write_block_tag kill-miss
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
# if the host already had it enabled. p3-pf-kill.txt is append-only: errors
# are dumped into it and it is never cleared.
enable_out="$(sudo -n /sbin/pfctl -E 2>&1)" || {
  printf '%s\n' "$enable_out" >>"$SESSION/p3-pf-kill.txt"
  echo "pfctl -E failed: $enable_out" >&2
  write_block_tag pf-anchor-unreachable
  exit 1
}
printf '%s\n' "$enable_out" >>"$SESSION/p3-pf-kill.txt"
PF_TOKEN="$(printf '%s\n' "$enable_out" | sed -n 's/.*Token *: *//p' | head -n 1)"
# pfctl -E enables pf and does not load /etc/pf.conf. The anchor below is
# evaluated only when the main ruleset hooks it. An empty ruleset never
# does, so a block loaded there matches nothing and the live socket keeps
# passing. A ruleset of `anchor "catcher"` evaluates that name instead.
if ! sudo -n /sbin/pfctl -sr >"$SESSION/p3-main-rules.txt" 2>>"$SESSION/p3-pf-kill.txt"; then
  echo "pfctl -sr failed" >&2
  write_block_tag pf-anchor-unreachable
  exit 1
fi
python3 - "$SESSION/p3-main-rules.txt" >"$SESSION/p3-ruleset.txt" <<'RULESET'
import sys
from pathlib import Path

lines = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    stripped = line.strip()
    if not stripped:
        continue
    if stripped.startswith("No ALTQ") or stripped.startswith("ALTQ related"):
        continue
    lines.append(stripped)
body = "\n".join(lines)
if 'anchor "com.apple/*"' in body:
    sys.stdout.write("com.apple\n")
elif not lines:
    sys.stdout.write("empty\n")
elif 'anchor "catcher"' in body:
    sys.stdout.write("catcher\n")
else:
    sys.stdout.write("foreign\n")
RULESET
MAIN="$(tr -d '[:space:]' <"$SESSION/p3-ruleset.txt")"
case "$MAIN" in
  com.apple) ;;
  empty)
    if ! stock_out="$(sudo -n /sbin/pfctl -f /etc/pf.conf 2>&1)"; then
      printf '%s\n' "$stock_out" | tee -a "$SESSION/p3-pf-kill.txt" >&2
      printf '%s\n' "none" >"$SESSION/p3-anchor.txt"
      echo "pf-anchor-unreachable: could not load /etc/pf.conf" >&2
      write_block_tag pf-anchor-unreachable
      exit 1
    fi
    PF_LOADED_STOCK=1
    printf '%s\n' "$stock_out" >>"$SESSION/p3-pf-kill.txt"
    ;;
  catcher)
    ANCHOR="catcher"
    ;;
  foreign)
    printf '%s\n' "none" >"$SESSION/p3-anchor.txt"
    echo "pf-anchor-unreachable: main ruleset has no com.apple/* or catcher anchor." >&2
    write_block_tag pf-anchor-unreachable
    exit 1
    ;;
  *)
    printf '%s\n' "none" >"$SESSION/p3-anchor.txt"
    echo "Could not classify the main pf ruleset (${MAIN:-missing})." >&2
    write_block_tag pf-anchor-unreachable
    exit 1
    ;;
esac
printf '%s\n' "$ANCHOR" >"$SESSION/p3-anchor.txt"
sudo -n /sbin/pfctl -a "$ANCHOR" -f "$RULE"
append_harness_field "$SESSION" pfOnWallMs "$(wall_ms)"
# pf passes a packet that matches an existing state without reading the rule.
# Kill those states and wait before the hold. A background -k let the socket
# die and reconnect while this script still called the block "on".
# Darwin does not treat a wildcard source as "any" for -k, so that form kills
# nothing and the established socket keeps passing. Kill the concrete pair,
# both directions, from the process sockets and from the state table.
# p3-pf-kill.txt is append-only, so this stderr stays with the earlier pfctl errors.
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
    r"\[([0-9A-Fa-f:.%]+)\][:.](\d+)"
    r"|(\d{1,3}(?:\.\d{1,3}){3})[:.](\d+)"
    r"|([0-9A-Fa-f:]+(?:%[0-9A-Za-z]+)?)\[(\d+)\]"
)

def endpoint_ip_port(match):
    if match.group(1) is not None:
        return match.group(1), match.group(2)
    if match.group(3) is not None:
        return match.group(3), match.group(4)
    return match.group(5), match.group(6)

emitted = set()
for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    found = []
    for match in endpoint.finditer(line):
        raw, port = endpoint_ip_port(match)
        ip = normalize(raw)
        if ip:
            found.append((ip, port))
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
kill_pair() {
  local src="$1" dst="$2" out
  if [[ -z "$src" || -z "$dst" ]]; then
    return 0
  fi
  if ! out="$(sudo -n /sbin/pfctl -k "$src" -k "$dst" 2>&1)"; then
    printf '%s\n' "$out" | tee -a "$SESSION/p3-pf-kill.txt" >&2
    printf '%s\n' "$out" >>"$SESSION/p3-kill-counts.txt"
    summarize_kills
    write_block_tag kill-miss
    exit 1
  fi
  printf '%s\n' "$out" >>"$SESSION/p3-pf-kill.txt"
  printf '%s\n' "$out" >>"$SESSION/p3-kill-counts.txt"
}
while read -r src dst; do
  kill_pair "$src" "$dst"
  kill_pair "$dst" "$src"
done <"$SESSION/p3-endpoints.txt"
while read -r src dst; do
  kill_pair "$src" "$dst"
  kill_pair "$dst" "$src"
done <"$SESSION/p3-state-pairs.txt"
summarize_kills
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
    r"\[([0-9A-Fa-f:.%]+)\][:.](\d+)"
    r"|(\d{1,3}(?:\.\d{1,3}){3})[:.](\d+)"
    r"|([0-9A-Fa-f:]+(?:%[0-9A-Za-z]+)?)\[(\d+)\]"
)

def endpoint_ip_port(match):
    if match.group(1) is not None:
        return match.group(1), match.group(2)
    if match.group(3) is not None:
        return match.group(3), match.group(4)
    return match.group(5), match.group(6)

for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    hit = False
    port443 = False
    for match in endpoint.finditer(line):
        raw, port = endpoint_ip_port(match)
        ip = normalize(raw)
        if port == "443":
            port443 = True
        if ip in peers:
            hit = True
    if hit and port443:
        sys.stderr.write(line + "\n")
        sys.exit(1)
STILL
then
  echo "The live :443 state is still installed, so packets would skip the new rule." >&2
  write_block_tag kill-miss
  exit 1
fi
# 15s after the states are gone. The first 2s are the proof that the out
# rule is actually matching. The engine's inbound stall is 5s, so the hole
# that remains still spans the 10s grade bar and reaches pf off.
sleep 2
# Counters come from the anchor this run loaded, not a hardcoded name.
if ! sudo -n /sbin/pfctl -a "$ANCHOR" -vsr >"$SESSION/p3-anchor-counters.txt" 2>>"$SESSION/p3-pf-kill.txt"; then
  printf '%s\n' "Packets:n/a" >"$SESSION/p3-out-packets.txt"
  echo "NOT_EFFECTIVE: could not read anchor counters." >&2
  write_block_tag NOT_EFFECTIVE
  exit 1
fi
python3 - "$SESSION/p3-anchor-counters.txt" >"$SESSION/p3-out-packets.txt" <<'COUNTERS'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
out_packets = None
pending_out = False
for line in text.splitlines():
    if "block drop out" in line:
        pending_out = True
        continue
    if pending_out:
        match = re.search(r"Packets:\s*(\d+)", line)
        if match:
            out_packets = int(match.group(1))
            pending_out = False
# A missing out rule is the same as a rule that never saw a packet.
sys.stdout.write("Packets:0\n" if out_packets is None else f"Packets:{out_packets}\n")
COUNTERS
OUT="$(sed -n 's/^Packets://p' "$SESSION/p3-out-packets.txt" | head -n 1 | tr -d '[:space:]')"
if [[ -z "$OUT" || "$OUT" == "0" || "$OUT" == "n/a" ]]; then
  echo "NOT_EFFECTIVE: catcher anchor out rule saw ${OUT:-0} packets." >&2
  write_block_tag NOT_EFFECTIVE
  exit 1
fi
write_block_tag ok
sleep 13
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
