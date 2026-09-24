#!/usr/bin/env bash
# The only entry that writes a board. Preflight first. A result other than
# PREFLIGHT RESULT PASS writes board.json and returns. No gate directory is
# created and play_fixture is never called.
#
# Gate order puts the destructive gates last: P4 mutes the speakers, P2
# revokes Screen Recording.
#
# usage: board.sh [--self-test] [--expect-sha SHA] [--expect-cdhash HEX] <parent-dir>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

SELF_TEST=0
EXPECT_SHA=""
EXPECT_CDHASH=""
PARENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    --expect-sha) EXPECT_SHA="${2:?}"; shift 2 ;;
    --expect-cdhash) EXPECT_CDHASH="${2:?}"; shift 2 ;;
    *)
      PARENT="$1"
      shift
      ;;
  esac
done
if [[ -z "$PARENT" ]]; then
  echo "usage: $0 [--self-test] [--expect-sha SHA] [--expect-cdhash HEX] <parent-dir>" >&2
  exit 2
fi
if [[ "$SELF_TEST" == 1 ]]; then
  EXPECT_SHA="${EXPECT_SHA:-b14e31a99a431e5cac6a49669f5c1955de38a1d1}"
  EXPECT_CDHASH="${EXPECT_CDHASH:-57250034b55e54e3ad6798983edf6e62c1553653}"
fi

mkdir -p "$PARENT"
SHORT="unknown"
if [[ -n "${CATCHER_APP:-}" && -f "${CATCHER_APP}/Contents/Info.plist" ]]; then
  plist_sha="$(plutil -extract CatcherGitSHA raw -o - "$CATCHER_APP/Contents/Info.plist" 2>/dev/null || true)"
  SHORT="${plist_sha:0:7}"
  if [[ -z "$SHORT" ]]; then
    SHORT="unknown"
  fi
fi
RUN="$PARENT/${SHORT}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN/obs"
export CATCHER_BOARD_RUN="$RUN"

compose() {
  local -a args=(python3 "$ROOT/board.py" compose --run "$RUN")
  if [[ -n "${1:-}" ]]; then
    args+=(--stopped "$1")
  fi
  if [[ -n "$EXPECT_SHA" ]]; then
    args+=(--expect-sha "$EXPECT_SHA")
  fi
  if [[ -n "$EXPECT_CDHASH" ]]; then
    args+=(--expect-cdhash "$EXPECT_CDHASH")
  fi
  "${args[@]}"
}

write_env() {
  local eligible="${CATCHER_GREEN_ELIGIBLE:-1}"
  python3 - "$RUN/obs/board-env.json" "$ROOT" "${CATCHER_APP:-}" "$eligible" <<'PY'
import json, os, platform, subprocess, sys
from pathlib import Path
path, root, app, eligible = sys.argv[1:]
sys.path.insert(0, root)
import board as board_mod
cdhash = ""
plist = ""
if app and Path(app).is_dir():
    try:
        sign = subprocess.run(board_mod.codesign_cdhash_args(app), capture_output=True, text=True)
    except OSError:
        sign = None
    if sign is not None:
        cdhash = board_mod.cdhash_from_codesign(sign.stderr + "\n" + sign.stdout)
    plist_path = Path(app) / "Contents" / "Info.plist"
    if plist_path.is_file():
        read = subprocess.run(
            ["plutil", "-extract", "CatcherGitSHA", "raw", "-o", "-", str(plist_path)],
            capture_output=True, text=True,
        )
        plist = read.stdout.strip()
sha = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
os_name = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
record = {
    "harnessGitSHA": sha,
    "catcherApp": app,
    "cdhash": cdhash,
    "catcherGitSHA": plist,
    "macOS": os_name or platform.platform(),
    "greenEligible": eligible == "1",
}
Path(path).write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
PY
}

write_env
if ! kill_orphans "$RUN/obs/orphans.jsonl"; then
  echo "orphan CatcherApp or fixture afplay survived. Board stopped." >&2
  compose orphans
  exit 1
fi
if [[ "${CATCHER_RIG_FAULT:-}" == "stray-instance" ]]; then
  python3 - "$RUN/obs/orphans.jsonl" <<'PY'
import json, sys
from pathlib import Path
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
killed = sum(len(row.get("killed") or []) for row in rows)
if killed < 1:
    raise SystemExit("stray-instance fault: the sweep killed nothing")
PY
fi

PRE="$RUN/preflight"
mkdir -p "$PRE"
export CATCHER_GATE=preflight
set +e
python3 "$ROOT/board.py" exec-gate \
  --timeout "$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["rigGateTimeoutS"]["preflight"]))' "$ROOT/thresholds.json")" \
  --log "$PRE/gate.log" \
  --obs "$PRE/rig_obs.json" \
  -- "$ROOT/run.sh" preflight "$PRE"
set -e
if [[ "${CATCHER_RIG_FAULT:-}" == "bad-preflight" ]]; then
  printf 'PREFLIGHT rig-fault FAIL error=bad-preflight source=harness\nPREFLIGHT RESULT FAIL failed=1 source=harness\n' >> "$PRE/preflight.txt"
fi
if ! require_preflight_pass "$PRE/preflight.txt" ""; then
  echo "preflight FAIL; board stopped. No gates and no afplay." >&2
  compose preflight
  exit 1
fi
CDHASH="$(tr -d '[:space:]' < "$PRE/preflight_cdhash.txt")"
export CATCHER_PREFLIGHT_REPORT="$PRE/preflight.txt"
export CATCHER_PREFLIGHT_CDHASH="$CDHASH"

timeout_for() {
  python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["rigGateTimeoutS"][sys.argv[2]]))' "$ROOT/thresholds.json" "$1"
}

run_one() {
  local gate="$1"
  shift
  local dir="$RUN/$gate"
  mkdir -p "$dir"
  if ! kill_orphans "$RUN/obs/orphans.jsonl"; then
    echo "orphan survived before $gate. Board stopped." >&2
    compose orphans
    exit 1
  fi
  export CATCHER_GATE="$gate"
  set +e
  python3 "$ROOT/board.py" exec-gate \
    --timeout "$(timeout_for "$gate")" \
    --log "$dir/gate.log" \
    --obs "$dir/rig_obs.json" \
    -- "$ROOT/run.sh" "$gate" "$dir" "$@"
  local status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "gate $gate exited $status" >&2
  fi
  return 0
}

run_one p1
run_one p5 "$RUN/p1"
run_one p3
run_one p6
run_one p4
run_one p2

set +e
python3 "$ROOT/verdict.py" --out "$RUN" --preflight "$PRE" \
  --p1 "$RUN/p1" --p2 "$RUN/p2" --p3 "$RUN/p3" \
  --p4 "$RUN/p4" --p5 "$RUN/p5" --p6 "$RUN/p6"
set -e
compose
