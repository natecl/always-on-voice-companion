#!/usr/bin/env bash
# Tier L. Fail-closed preflight cycle, ROOT, and raise=NO_PROCESS. Not a Mac gate.
set -euo pipefail
HARNESS="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

bash -c "
set -euo pipefail
unset ROOT || true
source '$HARNESS/lib.sh'
[[ \"\$ROOT\" == '$HARNESS' ]]
tmp=\$(mktemp -d)
begin_harness_run \"\$tmp\" P1
[[ -s \"\$tmp/harness_run.json\" ]]
" || fail "ROOT unbound or begin_harness_run did not write harness_run.json"

dead_pid() {
  sleep 30 &
  local pid=$!
  kill "$pid"
  wait "$pid" || true
  echo "$pid"
}

# Dead pid: helper must not run. Result is blocked, not a pass.
tmp="$(mktemp -d)"
pid="$(dead_pid)"
printf '%s\n' "$pid" > "$tmp/catcher.pid"
marker="$tmp/helper-called"
helper="$tmp/helper"
cat > "$helper" <<EOF
#!/bin/sh
echo called > "$marker"
echo "raise=OK pid=\$1"
exit 0
EOF
chmod +x "$helper"
(
  set -euo pipefail
  # shellcheck disable=SC1091
  source "$HARNESS/lib.sh"
  export CATCHER_ENSURE_WINDOW="$helper"
  if require_fixture_play "$tmp"; then
    echo "dead pid was treated as ready" >&2
    exit 1
  fi
)
grep -q 'raise=NO_PROCESS' "$tmp/raise.txt" || fail "dead pid did not record raise=NO_PROCESS"
python3 - "$tmp/blocked.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["result"] == "blocked", record
assert record["raise"] == "NO_PROCESS", record
assert record["softPass"] is False, record
assert "raise=NO_PROCESS" in record["evidence"]
PY
[[ ! -e "$marker" ]] || fail "window helper ran for a dead pid"

# Live pid, helper says the window is not up: still blocked, helper did run.
tmp="$(mktemp -d)"
sleep 60 &
pid=$!
printf '%s\n' "$pid" > "$tmp/catcher.pid"
marker="$tmp/helper-called"
helper="$tmp/helper"
cat > "$helper" <<EOF
#!/bin/sh
echo called > "$marker"
echo "raise=NOT_VISIBLE pid=\$1"
exit 1
EOF
chmod +x "$helper"
(
  set -euo pipefail
  source "$HARNESS/lib.sh"
  export CATCHER_ENSURE_WINDOW="$helper"
  if require_fixture_play "$tmp"; then
    exit 1
  fi
  exit 0
)
grep -q 'raise=NOT_VISIBLE' "$tmp/raise.txt" || fail "NOT_VISIBLE was not recorded"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["raise"]=="NOT_VISIBLE" and r["result"]=="blocked"' "$tmp/blocked.json"
[[ -s "$marker" ]] || fail "window helper did not run for a live pid"
kill "$pid" || true
wait "$pid" || true

# Live pid and a frontmost window: play may proceed. No blocked file.
tmp="$(mktemp -d)"
sleep 60 &
pid=$!
printf '%s\n' "$pid" > "$tmp/catcher.pid"
helper="$tmp/helper"
cat > "$helper" <<EOF
#!/bin/sh
echo "raise=OK pid=\$1"
exit 0
EOF
chmod +x "$helper"
(
  set -euo pipefail
  source "$HARNESS/lib.sh"
  export CATCHER_ENSURE_WINDOW="$helper"
  require_fixture_play "$tmp"
)
grep -q 'raise=OK' "$tmp/raise.txt" || fail "ready window was not raise=OK"
[[ ! -e "$tmp/blocked.json" ]] || fail "ready window wrote blocked.json"
kill "$pid" || true
wait "$pid" || true

# Preflight FAIL stops the cycle before any gate directory or afplay.
tmp="$(mktemp -d)"
mkdir -p "$tmp/preflight"
cat > "$tmp/preflight/preflight.txt" <<'EOF'
PREFLIGHT signing PASS
PREFLIGHT tcc-screen FAIL error="screen recording access denied"
PREFLIGHT capture-display FAIL error="no display"
PREFLIGHT RESULT FAIL failed=2
EOF
(
  set -euo pipefail
  source "$HARNESS/cycle.sh"
  run_cycle_gates() { echo ran > "$1/gates-ran"; }
  export CATCHER_SKIP_PREFLIGHT_LAUNCH=1
  if cycle_main "$tmp"; then
    echo "cycle treated preflight FAIL as pass" >&2
    exit 1
  fi
)
[[ ! -e "$tmp/gates-ran" ]] || fail "gates launched after preflight FAIL"
[[ ! -d "$tmp/p1" ]] || fail "p1 directory exists after preflight FAIL"
python3 - "$tmp/board.json" <<'PY'
import json, sys
board = json.load(open(sys.argv[1], encoding="utf-8"))
assert board["verdict"] == "RED", board
assert board["stopped"] == "preflight", board
assert board["preflight"] == "fail", board
assert board["gatesLaunched"] is False, board
assert board["afplay"] is False, board
assert board["softPass"] is False, board
assert board["hostWall"] == "screen-tcc", board
assert "re-grants" in board["hostWallNote"]
assert any("tcc-screen FAIL" in line for line in board["failedChecks"])
assert any("capture-display FAIL" in line for line in board["failedChecks"])
assert board["resultLine"].startswith("PREFLIGHT RESULT FAIL")
PY

# A missing report is a fail. Gates stay down.
tmp="$(mktemp -d)"
(
  set -euo pipefail
  source "$HARNESS/cycle.sh"
  run_cycle_gates() { echo ran > "$1/gates-ran"; }
  export CATCHER_SKIP_PREFLIGHT_LAUNCH=1
  if cycle_main "$tmp"; then
    exit 1
  fi
)
[[ ! -e "$tmp/gates-ran" ]] || fail "gates launched with no preflight report"
python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); assert b["gatesLaunched"] is False and b["verdict"]=="RED"' "$tmp/board.json"

# PASS reaches the gate launcher and does not write a preflight-fail board.
tmp="$(mktemp -d)"
mkdir -p "$tmp/preflight"
printf 'PREFLIGHT RESULT PASS\n' > "$tmp/preflight/preflight.txt"
(
  set -euo pipefail
  source "$HARNESS/cycle.sh"
  run_cycle_gates() { echo ran > "$1/gates-ran"; return 0; }
  export CATCHER_SKIP_PREFLIGHT_LAUNCH=1
  cycle_main "$tmp"
)
[[ -s "$tmp/gates-ran" ]] || fail "PASS did not reach the gate launcher"
[[ ! -e "$tmp/board.json" ]] || fail "PASS wrote a preflight-fail board"

# Hang after signing is a preflight-finish FAIL, not a Screen TCC host wall.
tmp="$(mktemp -d)"
printf 'PREFLIGHT signing PASS\n' > "$tmp/preflight.txt"
(
  set -euo pipefail
  source "$HARNESS/lib.sh"
  append_preflight_finish_fail "$tmp/preflight.txt" hang-after-signing
  append_preflight_finish_fail "$tmp/preflight.txt" hang-after-signing
)
result_count="$(grep -c '^PREFLIGHT RESULT ' "$tmp/preflight.txt")"
[[ "$result_count" == "1" ]] || fail "hang line duplicated the RESULT"
grep -q 'error=hang-after-signing' "$tmp/preflight.txt" || fail "missing hang-after-signing"
if grep -q 'tcc-screen' "$tmp/preflight.txt"; then
  fail "hang-after-signing was written as a screen check"
fi
mkdir -p "$tmp/run/preflight"
cp "$tmp/preflight.txt" "$tmp/run/preflight/preflight.txt"
(
  set -euo pipefail
  source "$HARNESS/cycle.sh"
  run_cycle_gates() { echo ran > "$1/gates-ran"; }
  export CATCHER_SKIP_PREFLIGHT_LAUNCH=1
  if cycle_main "$tmp/run"; then
    exit 1
  fi
)
[[ ! -e "$tmp/run/gates-ran" ]] || fail "gates launched after hang-after-signing"
python3 - "$tmp/run/board.json" <<'PY'
import json, sys
board = json.load(open(sys.argv[1], encoding="utf-8"))
assert board["verdict"] == "RED", board
assert board["gatesLaunched"] is False, board
assert board["afplay"] is False, board
assert board["hangAfterSigning"] is True, board
assert board["hostWall"] is None, board
assert board["softPass"] is False, board
assert "hang-after-signing" in " ".join(board["failedChecks"])
PY

# Fixture play stays behind the window gate in every script that calls afplay.
python3 - "$HARNESS" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for name in ("p1_known_audio.sh", "p3_net_kill.sh", "p5_stub.sh", "p6_two_track.sh"):
    text = (root / name).read_text(encoding="utf-8")
    play = text.index('afplay "$ROOT/fixtures')
    gate = text.index("require_fixture_play")
    if gate > play:
        raise SystemExit(f"{name} plays the fixture before require_fixture_play")
pf = (root / "p3_net_kill.sh").read_text(encoding="utf-8")
if pf.count("sudo -n /sbin/pfctl") < 5:
    raise SystemExit("p3 pfctl wrap regressed")
if 'ANCHOR="com.apple/catcher"' not in pf or '-a "$ANCHOR"' not in pf or "pfctl -E" not in pf:
    raise SystemExit("p3 block is not an evaluated com.apple anchor with pf enabled")
if "0.0.0.0/0" in pf or "::/0" in pf:
    raise SystemExit("p3 state kill still uses a wildcard source")
if "api.deepgram.com" in pf or "-iUDP:443" not in pf:
    raise SystemExit("p3 peer scan regressed")
if "pf-anchor-unreachable" not in pf or "write_block_tag NOT_EFFECTIVE" not in pf:
    raise SystemExit("p3 does not fail closed when the anchor is unreachable or idle")
if "write_block_tag kill-miss" not in pf or "write_block_tag ok" not in pf:
    raise SystemExit("p3 block tag is missing kill-miss or ok")
for artifact in (
    "p3-ruleset.txt",
    "p3-anchor.txt",
    "p3-main-rules.txt",
    "p3-lsof-peers.txt",
    "p3-kill-counts.txt",
    "p3-out-packets.txt",
    "p3-block.txt",
    "p3-obs.txt",
):
    if f"$SESSION/{artifact}" not in pf:
        raise SystemExit(f"p3 artifact {artifact} is not written under the session")
kill_at = 0
while True:
    kill_at = pf.find('>"$SESSION/p3-pf-kill.txt"', kill_at)
    if kill_at < 0:
        break
    if kill_at == 0 or pf[kill_at - 1] != ">":
        raise SystemExit("p3-pf-kill.txt is truncated instead of appended")
    kill_at += 1
if '>>"$SESSION/p3-pf-kill.txt"' not in pf:
    raise SystemExit("p3-pf-kill.txt does not keep pfctl errors")
cleanup = pf.split("cleanup() {", 1)[1].split("\n}", 1)[0]
rm_lines = [line.strip() for line in cleanup.splitlines() if "rm " in line]
if rm_lines != ['rm -f "$RULE"']:
    raise SystemExit(f"cleanup removes a p3 artifact: {rm_lines}")
if "PF_LOADED_STOCK" not in pf or "sudo -n /sbin/pfctl -F rules" not in pf or "/etc/pf.conf" not in pf:
    raise SystemExit("p3 does not load stock pf.conf and restore an empty main ruleset")
load = pf.index('-a "$ANCHOR" -f "$RULE"')
if pf.index('pfctl -sr >"$SESSION/p3-main-rules.txt"') > load:
    raise SystemExit("main ruleset is inspected after the anchor is loaded")
catcher_arm = pf.split("\n  catcher)", 1)[1].split("\n  foreign)", 1)[0]
if 'ANCHOR="catcher"' not in catcher_arm or "pf-anchor-unreachable" in catcher_arm:
    raise SystemExit("top-level catcher anchor does not proceed")
if pf.index('ANCHOR="catcher"') > load:
    raise SystemExit("catcher anchor is selected after the rules are loaded")
foreign_arm = pf.split("\n  foreign)", 1)[1].split("\n  *)", 1)[0]
foreign_tag = pf.index("write_block_tag pf-anchor-unreachable", pf.index("\n  foreign)"))
if "write_block_tag pf-anchor-unreachable" not in foreign_arm or foreign_tag > load:
    raise SystemExit("missing hook does not tag pf-anchor-unreachable before pfOn")
not_at = pf.index("write_block_tag NOT_EFFECTIVE")
off_at = pf.index('append_harness_field "$SESSION" pfOffWallMs')
if not_at > off_at or pf.index("sleep 2") > not_at or pf.index("sleep 13") < not_at:
    raise SystemExit("packet proof is not inside the 15s hold, before pfOff")
ok_at = pf.index("write_block_tag ok")
if pf.index("sleep 2") > ok_at or ok_at > pf.index("sleep 13") or ok_at > off_at:
    raise SystemExit("ok is not written after a nonzero packet count and before pfOff")
miss_at = 0
while True:
    miss_at = pf.find("write_block_tag kill-miss", miss_at)
    if miss_at < 0:
        break
    if miss_at > off_at:
        raise SystemExit("kill-miss is written after pfOff")
    miss_at += 1
kill_line = pf.split("pfctl -k", 1)[1].split("\n", 1)[0]
if kill_line.rstrip().endswith("&"):
    raise SystemExit("p3 state kill is backgrounded, so the socket can reconnect during the block")
if "CATCHER_ALLOW_PF" not in pf:
    raise SystemExit("CATCHER_ALLOW_PF gate missing")
if "python3 - " in pf and '<<\'PY\'' in pf:
    py_at = pf.index("<<'PY'")
    window = pf[max(0, py_at - 180):py_at]
    if 'NEED="$(' in window or window.rstrip().endswith('"$('):
        raise SystemExit("p3 heredoc is still inside a double-quoted substitution")
else:
    raise SystemExit("p3 python body is not a quoted heredoc")
if '>"$SESSION/p3-need.txt" <<\'PY\'' not in pf:
    raise SystemExit("p3 python body is not written outside $(...)")
pre = (root / "preflight.sh").read_text(encoding="utf-8")
if "open -n -W" in pre:
    raise SystemExit("preflight still waits on open -W")
if "hang-after-signing" not in pre:
    raise SystemExit("preflight has no hang-after-signing timeout")
lib = (root / "lib.sh").read_text(encoding="utf-8")
if '"$helper" "$pid" "$session"' not in lib:
    raise SystemExit("ensure_window is not passed the session")
if "require_fixture_play \"$session\"" not in lib.split("launch_catcher()")[1].split("resolve_session()")[0]:
    raise SystemExit("launch_catcher returns before the content window is raised")
helper_src = (root / "ensure_window.swift").read_text(encoding="utf-8")
if "listedOnScreen()" in helper_src:
    raise SystemExit("raise=OK must require window_front, not a window list")
app = (root.parent / "Sources" / "CatcherApp" / "CatcherApp.swift").read_text(encoding="utf-8")
if "assumeIsolated" in app:
    raise SystemExit("harness Timer still calls assumeIsolated")
if "applicationShouldTerminateAfterLastWindowClosed" not in app:
    raise SystemExit("harness launch can still quit when the window closes")
if "NSHostingController" not in app or ".suppressed" not in app:
    raise SystemExit("harness does not open its own key content window")
if "setActivationPolicy" not in app.split("applicationWillFinishLaunching")[1].split("applicationDidFinishLaunching")[0]:
    raise SystemExit("activation policy is not set before the window")

import subprocess
import tempfile

def heredoc(name):
    marker = "<<'" + name + "'"
    start = pf.index(marker) + len(marker)
    body = pf[start:]
    if body.startswith("\n"):
        body = body[1:]
    end = body.index("\n" + name + "\n")
    return body[:end]

peers_py = heredoc("PEERS")
states_py = heredoc("STATES")
still_py = heredoc("STILL")
rules_py = heredoc("RULESET")
count_py = heredoc("COUNTERS")
kcounts_py = heredoc("KCOUNTS")

def run_py(script, args):
    return subprocess.run(
        [sys.executable, "-"] + args,
        input=script,
        text=True,
        capture_output=True,
    )

with tempfile.TemporaryDirectory() as tmp:
    session = pathlib.Path(tmp)
    tcp = session / "tcp.txt"
    udp = session / "udp.txt"
    dig = session / "dig.txt"
    tcp.write_text(
        "n10.0.0.5:50000->208.184.56.201:443\n"
        "n[fe80::1%en0]:50001->[2606:4700::6812:1250]:443\n"
        "n10.0.0.5:50002->::ffff:208.184.56.201:443\n",
        encoding="utf-8",
    )
    udp.write_text("n10.0.0.5:50003->208.184.56.201:443\n", encoding="utf-8")
    dig.write_text("cname.example.\n104.18.18.80\n", encoding="utf-8")
    got = run_py(peers_py, [str(session), str(tcp), str(udp), str(dig)])
    if got.returncode != 0:
        raise SystemExit(got.stderr)
    endpoints = (session / "p3-endpoints.txt").read_text(encoding="utf-8")
    table = (session / "p3-table-ips.txt").read_text(encoding="utf-8").split()
    if "208.184.56.201" not in endpoints or "2606:4700::6812:1250" not in endpoints:
        raise SystemExit(f"live peers dropped: {endpoints}")
    if "::ffff:" in endpoints:
        raise SystemExit(f"mapped peer was not rewritten: {endpoints}")
    if "208.184.56.201" not in table or "104.18.18.80" not in table:
        raise SystemExit(f"table missed a peer or dig address: {table}")
    if "cname.example" in table:
        raise SystemExit("CNAME leaked into the pf table")
    (session / "none.txt").write_text("n*:443\np99\n", encoding="utf-8")
    missing = run_py(peers_py, [str(session), str(session / "none.txt"), str(session / "none.txt"), str(dig)])
    if missing.returncode == 0:
        raise SystemExit("p3 accepts a dig-only table when the process has no :443 peer")
    states = session / "states.txt"
    states.write_text(
        "all tcp 10.0.0.5:50000 -> 208.184.56.201:443 ESTABLISHED:ESTABLISHED\n"
        "all tcp 1.2.3.4:443 (10.0.0.8:9) -> 104.18.18.80:443 ESTABLISHED:ESTABLISHED\n"
        "all tcp 10.9.9.9:1 -> 9.9.9.9:443 ESTABLISHED:ESTABLISHED\n"
        "all tcp 2606:4700::6812:1250[443] <- 2606:4700:1::20[50000]\n",
        encoding="utf-8",
    )
    (session / "p3-table-ips.txt").write_text(
        "208.184.56.201\n104.18.18.80\n2606:4700::6812:1250\n",
        encoding="utf-8",
    )
    listed = run_py(states_py, [str(states), str(session / "p3-table-ips.txt")])
    if listed.returncode != 0:
        raise SystemExit(listed.stderr)
    pairs = listed.stdout.splitlines()
    if "10.0.0.5 208.184.56.201" not in pairs:
        raise SystemExit(f"state pair missing: {pairs}")
    if "2606:4700:1::20 2606:4700::6812:1250" not in pairs:
        raise SystemExit(f"ipv6 addr[port] state was not parsed: {pairs}")
    if "10.0.0.8 104.18.18.80" not in pairs or "1.2.3.4 104.18.18.80" not in pairs:
        raise SystemExit(f"nat state pair missing: {pairs}")
    if any("9.9.9.9" in pair for pair in pairs):
        raise SystemExit(f"unrelated state was selected: {pairs}")
    (session / "p3-endpoints.txt").write_text("10.0.0.5 208.184.56.201\n", encoding="utf-8")
    stuck = run_py(still_py, [str(states), str(session / "p3-endpoints.txt")])
    if stuck.returncode == 0:
        raise SystemExit("a remaining live peer state was treated as cleared")
    clear = session / "clear.txt"
    clear.write_text(
        "all tcp 1.2.3.4:443 -> 104.18.18.80:443 ESTABLISHED:ESTABLISHED\n",
        encoding="utf-8",
    )
    other = run_py(still_py, [str(clear), str(session / "p3-endpoints.txt")])
    if other.returncode != 0:
        raise SystemExit("another app's Cloudflare state aborted the block: " + other.stderr)

    def classify(text):
        path = session / "rules.txt"
        path.write_text(text, encoding="utf-8")
        got = run_py(rules_py, [str(path)])
        if got.returncode != 0:
            raise SystemExit(got.stderr)
        return got.stdout.strip()

    if classify("No ALTQ support in kernel\nALTQ related functions disabled\n") != "empty":
        raise SystemExit("ALTQ banner was treated as a main ruleset")
    if classify('anchor "com.apple/*"\npass out all\n') != "com.apple":
        raise SystemExit("com.apple/* anchor was not treated as reachable")
    if classify('anchor "catcher" all\n') != "catcher":
        raise SystemExit("top-level catcher anchor was treated as unreachable")
    if classify("pass out quick all\n") != "foreign":
        raise SystemExit("foreign ruleset without the hook was allowed")

    def packets(text):
        path = session / "counters.txt"
        path.write_text(text, encoding="utf-8")
        got = run_py(count_py, [str(path)])
        if got.returncode != 0:
            raise SystemExit(got.stderr)
        return got.stdout.strip()

    if packets(
        "block drop out quick proto tcp from any to <catcher_xai> port = 443\n"
        "  [ Evaluations: 10 Packets: 0 Bytes: 0 States: 0 ]\n"
    ) != "Packets:0":
        raise SystemExit("a zero out-rule packet count would hold the block")
    normal = packets(
        "block drop out quick proto tcp from any to <catcher_xai> port = 443\n"
        "  [ Evaluations: 10 Packets: 42 Bytes: 100 States: 0 ]\n"
        "block drop in quick proto tcp from <catcher_xai> port = 443 to any\n"
        "  [ Evaluations: 1 Packets: 0 Bytes: 0 States: 0 ]\n"
    )
    if normal != "Packets:42":
        raise SystemExit(f"out-rule packet count parsed as {normal}")

    counts = session / "kills.txt"
    counts.write_text(
        "killed 0 states from 1 sources and 1 destinations\n"
        "killed 2 states from 1 sources and 1 destinations\n",
        encoding="utf-8",
    )
    summed = run_py(kcounts_py, [str(counts)])
    if summed.returncode != 0:
        raise SystemExit(summed.stderr)
    if not summed.stdout.startswith("states_killed=2\n"):
        raise SystemExit(f"kill counts were not summed: {summed.stdout!r}")
    if "killed 0 states" not in summed.stdout or "killed 2 states" not in summed.stdout:
        raise SystemExit("kill count lines were dropped")

obs_start = pf.index("# OBS_START\n") + len("# OBS_START\n")
obs_end = pf.index("# OBS_END\n")
funcs = pf[obs_start:obs_end]

def run_obs(tmp, body):
    script = tmp / "obs.sh"
    script.write_text(funcs + "\n" + body, encoding="utf-8")
    got = subprocess.run(
        ["bash", str(script)],
        cwd=tmp,
        text=True,
        capture_output=True,
        env={**os.environ, "SESSION": str(tmp)},
    )
    if got.returncode != 0:
        raise SystemExit(got.stderr or got.stdout)
    names = (
        "p3-ruleset.txt",
        "p3-anchor.txt",
        "p3-main-rules.txt",
        "p3-lsof-peers.txt",
        "p3-kill-counts.txt",
        "p3-out-packets.txt",
        "p3-block.txt",
        "p3-obs.txt",
    )
    for name in names:
        path = tmp / name
        if not path.is_file() or not path.read_text(encoding="utf-8").strip():
            raise SystemExit(f"{name} missing after {body}")
    return (tmp / "p3-block.txt").read_text(encoding="utf-8").strip(), (
        tmp / "p3-obs.txt"
    ).read_text(encoding="utf-8")

import os

with tempfile.TemporaryDirectory() as raw:
    tmp = pathlib.Path(raw)
    (tmp / "p3-ruleset.txt").write_text("foreign\n", encoding="utf-8")
    (tmp / "p3-anchor.txt").write_text("none\n", encoding="utf-8")
    (tmp / "p3-main-rules.txt").write_text('pass out quick all\n', encoding="utf-8")
    (tmp / "p3-lsof-peers.txt").write_text("10.0.0.5 104.18.18.80\n", encoding="utf-8")
    tag, obs = run_obs(tmp, "write_block_tag pf-anchor-unreachable\n")
    if tag != "pf-anchor-unreachable" or "ruleset=foreign" not in obs or "anchor=none" not in obs:
        raise SystemExit(f"missing-hook artifacts: {tag} {obs}")
    (tmp / "p3-ruleset.txt").write_text("com.apple\n", encoding="utf-8")
    (tmp / "p3-anchor.txt").write_text("com.apple/catcher\n", encoding="utf-8")
    (tmp / "p3-out-packets.txt").write_text("Packets:0\n", encoding="utf-8")
    tag, obs = run_obs(tmp, "write_block_tag NOT_EFFECTIVE\n")
    if tag != "NOT_EFFECTIVE" or "packets=Packets:0" not in obs:
        raise SystemExit(f"zero-packet artifacts: {tag} {obs}")
    (tmp / "p3-ruleset.txt").write_text("catcher\n", encoding="utf-8")
    (tmp / "p3-anchor.txt").write_text("catcher\n", encoding="utf-8")
    (tmp / "p3-out-packets.txt").write_text("Packets:42\n", encoding="utf-8")
    (tmp / "p3-kill-counts.txt").write_text("states_killed=0\n", encoding="utf-8")
    tag, obs = run_obs(tmp, "write_block_tag ok\n")
    if tag != "ok" or "ruleset=catcher" not in obs or "anchor=catcher" not in obs or "packets=Packets:42" not in obs:
        raise SystemExit(f"catcher-anchor artifacts: {tag} {obs}")
PY

echo "cycle guard ok"
