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
if "CATCHER_ALLOW_PF" not in pf:
    raise SystemExit("CATCHER_ALLOW_PF gate missing")
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
PY

echo "cycle guard ok"
