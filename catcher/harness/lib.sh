#!/usr/bin/env bash
# Shared helpers. Launch through LaunchServices. A binary exec'd from a shell
# keeps the shell's app (Terminal, Cursor, iTerm, the agent host) as its TCC
# responsible process: microphone status is read for that app, the Allow dialog
# names that app, and com.catcher.app never appears in the Microphone pane.
# Stock `open` has no --env, so the helper calls NSWorkspace and passes the
# full environment (CATCHER_* and XAI_API_KEY included). The same switches also
# go through --args. There is no direct-exec fallback.
set -euo pipefail

# Harness directory. This file is sourced, so the caller's $0 is not this
# path. Gate wrappers and run.sh do not have to export ROOT first. An unbound
# ROOT under set -u aborted begin_harness_run and launch_via_workspace before
# any grade.json or events.jsonl existed.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

catcher_bin() {
  local app="${CATCHER_APP:-}"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "Set CATCHER_APP to the built Catcher.app. The granted TCC identity is the app bundle, not Terminal or Xcode." >&2
    return 2
  fi
  local bin="$app/Contents/MacOS/CatcherApp"
  if [[ ! -x "$bin" ]]; then
    echo "Missing executable $bin. Build with catcher/scripts/build-app.sh." >&2
    return 2
  fi
  require_stable_signature "$app"
  echo "$bin"
}

# Ad-hoc signatures key TCC to the cdhash, which changes every rebuild.
# A stable certificate keys it to the cert plus com.catcher.app.
require_stable_signature() {
  local app="$1"
  if ! command -v codesign >/dev/null 2>&1; then
    echo "codesign is not available; cannot verify $app" >&2
    return 2
  fi
  local info
  info="$(codesign -dv "$app" 2>&1 || true)"
  if grep -q "Signature=adhoc" <<<"$info"; then
    echo "Catcher.app is ad-hoc signed (Signature=adhoc). TCC would follow this build's cdhash and will not survive the next rebuild." >&2
    echo "Rebuild with catcher/scripts/build-app.sh so the identity is the stable Catcher Development certificate (or Apple Development when CATCHER_DEVELOPMENT_TEAM is set)." >&2
    echo "$info" | grep -E "Signature=|TeamIdentifier=|CDHash=" >&2 || true
    return 2
  fi
  local bid=""
  if command -v plutil >/dev/null 2>&1; then
    bid="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [[ "$bid" != "com.catcher.app" ]]; then
    echo "Catcher.app bundle id is '${bid:-missing}', expected com.catcher.app. The harness must launch that bundle, not a swift run binary." >&2
    return 2
  fi
  # Hardened runtime without the audio-input entitlement: TCC opens no
  # microphone case, so there is no Allow and no row in the Microphone pane.
  local info
  info="$(codesign -dv "$app" 2>&1 || true)"
  if grep -q "flags=.*runtime" <<<"$info"; then
    if ! codesign -d --entitlements :- "$app" 2>/dev/null | grep -q "com.apple.security.device.audio-input"; then
      echo "Catcher.app is hardened (flags=runtime) without com.apple.security.device.audio-input. macOS will not ask for the microphone. Rebuild with catcher/scripts/build-app.sh." >&2
      return 2
    fi
  fi
}

# Provenance for grade.py and verdict.py. Written once per gate run, before
# launch, at <root>/harness_run.json (the parent of the <uuid> session). Not
# tamper-proof: it proves "ran through this harness on a Mac", nothing more.
begin_harness_run() {
  local root="$1"
  local gate="$2"
  local app="${CATCHER_APP:-}"
  mkdir -p "$root"
  local sign="" plist_sha=""
  if [[ -n "$app" && -d "$app" ]]; then
    sign="$(codesign -dvvv "$app" 2>&1 || true)"
    plist_sha="$(plutil -extract CatcherGitSHA raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  fi
  HR_ROOT="$root" HR_GATE="$gate" HR_APP="$app" HR_SIGN="$sign" HR_PLIST_SHA="$plist_sha" \
  HR_OS="$(sw_vers -productVersion 2>/dev/null || true)" \
  HR_ARCH="$(uname -m)" \
  HR_MODEL="$(sysctl -n hw.model 2>/dev/null || true)" \
  HR_HARNESS_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)" \
  HR_ENGINE="${CATCHER_ENGINE:-}" \
  python3 - <<'PY'
import json, os, platform, time
sign = os.environ["HR_SIGN"]
def field(name):
    return [line.split("=", 1)[1] for line in sign.splitlines() if line.startswith(name + "=")]
record = {
    "gate": os.environ["HR_GATE"],
    "startedWallMs": int(time.time() * 1000),
    "host": platform.system(),
    "macOS": os.environ["HR_OS"],
    "arch": os.environ["HR_ARCH"],
    "hwModel": os.environ["HR_MODEL"],
    "catcherApp": os.environ["HR_APP"],
    "catcherGitSHA": os.environ["HR_PLIST_SHA"],
    "catcherEngine": os.environ["HR_ENGINE"],
    "harnessGitSHA": os.environ["HR_HARNESS_SHA"],
    "codesign": {
        "cdhash": (field("CDHash") or [""])[0],
        "teamIdentifier": (field("TeamIdentifier") or [""])[0],
        "signature": (field("Signature") or [""])[0],
        "authority": field("Authority"),
    },
}
path = os.path.join(os.environ["HR_ROOT"], "harness_run.json")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
PY
}

# append_harness_field <root> <key> <int>. Gate scripts stamp their own wall
# times (P2 revokeWallMs, P3 pfOnWallMs / pfOffWallMs).
append_harness_field() {
  local root="$1"
  python3 - "$root/harness_run.json" "$2" "$3" <<'PY'
import json, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    record = json.load(handle)
record[key] = int(value)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
PY
}

wall_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

# NSWorkspace.openApplication, not a shell exec. The helper inherits this
# process's environment and hands that dictionary to LaunchServices, so
# CATCHER_SESSION_ROOT, CATCHER_HARNESS, CATCHER_AUTO_RECORD, CATCHER_ENGINE,
# and XAI_API_KEY arrive intact. Arguments are the same switches.
launch_via_workspace() {
  local app="$1"
  shift
  local src="$ROOT/launch_services.swift"
  local bin="${TMPDIR:-/tmp}/catcher-launch-services"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    if ! swiftc -O -framework AppKit -o "$bin" "$src"; then
      echo "Cannot compile the LaunchServices helper ($src)." >&2
      echo "Refusing to exec Catcher from the shell: TCC would bill this terminal's app, not com.catcher.app." >&2
      return 1
    fi
  fi
  "$bin" "$app" "$@"
}

wait_for_recording() {
  local root="$1"
  local waited=0
  while [[ "$waited" -lt 150 ]]; do
    if python3 - "$root" <<'PY'
import os, sys
root = sys.argv[1]
live = os.path.join(root, "live_session")
if os.path.isfile(live) and os.path.getsize(live) > 0:
    raise SystemExit(0)
if os.path.isfile(os.path.join(root, "events.jsonl")):
    raise SystemExit(0)
if os.path.isdir(root):
    for name in os.listdir(root):
        if os.path.isfile(os.path.join(root, name, "events.jsonl")):
            raise SystemExit(0)
raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  echo "Catcher did not start a recording under $root within 15 s." >&2
  return 1
}

# Launch com.catcher.app as its own TCC identity. The app writes its pid to
# <session>/catcher.pid once it is up (CATCHER_HARNESS=1); wait for that file.
launch_catcher() {
  local session="$1"
  local auto="${2:-1}"
  local bin app
  bin="$(catcher_bin)"
  app="$CATCHER_APP"
  export CATCHER_SESSION_ROOT="$session"
  export CATCHER_HARNESS=1
  local -a args=(--session-root "$session" --harness)
  local -a envs=(--env "CATCHER_SESSION_ROOT=$session" --env "CATCHER_HARNESS=1")
  if [[ -n "${CATCHER_ENGINE:-}" ]]; then
    args+=(--engine "$CATCHER_ENGINE")
    envs+=(--env "CATCHER_ENGINE=$CATCHER_ENGINE")
  fi
  if [[ -n "${XAI_API_KEY:-}" ]]; then
    envs+=(--env "XAI_API_KEY=$XAI_API_KEY")
  fi
  if [[ "$auto" == "1" ]]; then
    export CATCHER_AUTO_RECORD=1
    args+=(--auto-record)
    envs+=(--env "CATCHER_AUTO_RECORD=1")
  else
    # The record launch exports this. A recovery relaunch must not inherit it,
    # or it opens a second empty session and that directory is what gets graded.
    unset CATCHER_AUTO_RECORD
  fi
  rm -f "$session/catcher.pid"
  if open --help 2>&1 | grep -q -- '--env'; then
    open -n "$app" "${envs[@]}" --args "${args[@]}"
  else
    launch_via_workspace "$app" "${args[@]}"
  fi
  local waited=0
  while [[ ! -s "$session/catcher.pid" && "$waited" -lt 150 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [[ ! -s "$session/catcher.pid" ]]; then
    echo "Catcher did not write $session/catcher.pid within 15 s." >&2
    return 1
  fi
}

resolve_session() {
  local root="$1"
  python3 - "$root" <<'PY'
import os, sys
root = sys.argv[1]
direct = os.path.join(root, "events.jsonl")
if os.path.isfile(direct):
    print(root)
    raise SystemExit
found = []
if os.path.isdir(root):
    for name in os.listdir(root):
        events = os.path.join(root, name, "events.jsonl")
        if os.path.isfile(events):
            found.append((os.path.getmtime(events), os.path.join(root, name)))
if not found:
    sys.stderr.write(f"no events.jsonl under {root}\n")
    raise SystemExit(1)
found.sort()
print(found[-1][1])
PY
}

# Last line of preflight.txt is the verdict. Anything else is a fail.
preflight_is_pass() {
  local report="$1"
  [[ -f "$report" ]] || return 1
  local last
  last="$(tail -n 1 "$report" | tr -d '\r')"
  [[ "$last" == "PREFLIGHT RESULT PASS"* ]]
}

# Board for a preflight that did not pass. P1–P6 have not been launched.
# A tcc-screen FAIL is a host wall: Cap re-arms after Nathan re-grants.
write_preflight_board() {
  local run="$1"
  local report="$2"
  python3 - "$run/board.json" "$report" <<'PY'
import json, sys
from pathlib import Path

board_path, report_path = sys.argv[1], sys.argv[2]
text = ""
if report_path and Path(report_path).is_file():
    text = Path(report_path).read_text(encoding="utf-8")
lines = [line for line in text.splitlines() if line.strip()]
failed = [
    line for line in lines
    if line.startswith("PREFLIGHT ") and " FAIL" in line and not line.startswith("PREFLIGHT RESULT ")
]
result = next((line for line in reversed(lines) if line.startswith("PREFLIGHT RESULT ")), "")
host_wall = None
note = ""
if any(line.startswith("PREFLIGHT tcc-screen FAIL") for line in failed):
    host_wall = "screen-tcc"
    note = (
        "Screen TCC deny is a host wall. Cap re-arms after Nathan re-grants "
        "Screen & System Audio Recording for com.catcher.app. Not a soft-pass."
    )
record = {
    "verdict": "RED",
    "stopped": "preflight",
    "preflight": "fail",
    "resultLine": result,
    "failedChecks": failed,
    "gatesLaunched": False,
    "afplay": False,
    "softPass": False,
    "hostWall": host_wall,
    "hostWallNote": note,
    "report": report_path,
}
Path(board_path).parent.mkdir(parents=True, exist_ok=True)
Path(board_path).write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
PY
}

# Fixture audio waits until catcher.pid is alive and the content window is
# frontmost and on screen. A missing or dead pid is raise=NO_PROCESS.
require_fixture_play() {
  local session="$1"
  local evidence status=0
  evidence="$(ensure_catcher_window "$session")" || status=$?
  printf '%s\n' "$evidence" > "$session/raise.txt"
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$evidence" >&2
    write_blocked "$session" "$evidence"
    return "$status"
  fi
}

ensure_catcher_window() {
  local session="$1"
  local pid=""
  if [[ -s "$session/catcher.pid" ]]; then
    pid="$(tr -cd '0-9' < "$session/catcher.pid")"
  fi
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    echo "raise=NO_PROCESS pid=${pid:-missing} session=$session"
    return 1
  fi
  local helper="${CATCHER_ENSURE_WINDOW:-}"
  if [[ -z "$helper" ]]; then
    helper="$(compile_ensure_window)" || {
      echo "raise=NO_HELPER pid=$pid session=$session"
      return 1
    }
  fi
  "$helper" "$pid"
}

compile_ensure_window() {
  local src="$ROOT/ensure_window.swift"
  local bin="${TMPDIR:-/tmp}/catcher-ensure-window"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    if ! swiftc -O -framework AppKit -o "$bin" "$src"; then
      return 1
    fi
  fi
  echo "$bin"
}

write_blocked() {
  local session="$1"
  local evidence="$2"
  python3 - "$session/blocked.json" "$evidence" <<'PY'
import json, sys
from pathlib import Path

path, evidence = sys.argv[1], sys.argv[2]
token = ""
if evidence.startswith("raise="):
    token = evidence.split("=", 1)[1].split()[0]
record = {
    "result": "blocked",
    "raise": token,
    "evidence": evidence,
    "softPass": False,
}
Path(path).write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
PY
}
