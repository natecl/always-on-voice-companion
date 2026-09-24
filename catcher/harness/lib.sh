#!/usr/bin/env bash
# Shared helpers. Launch through LaunchServices. A binary exec'd from a shell
# keeps the shell's app (Terminal, Cursor, iTerm, the agent host) as its TCC
# responsible process: microphone status is read for that app, the Allow dialog
# names that app, and com.catcher.app never appears in the Microphone pane.
# Stock `open` has no --env, so the helper calls NSWorkspace and passes the
# full environment (CATCHER_* and XAI_API_KEY included). The same switches also
# go through --args. There is no direct-exec fallback.
set -euo pipefail

# Sourced by the gate scripts. Prefer the caller's ROOT, and fall back to
# this file so a direct source under `set -u` still finds the helpers.
if [[ -z "${ROOT:-}" ]]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

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

# Write <root>/rig_obs.json atomically. The grader's rig:evidence premise
# reads this file; a partial write would look like a missing premise.
rig_obs_write() {
  local root="$1"
  local payload="$2"
  python3 - "$root/rig_obs.json" "$payload" <<'PY'
import json, os, sys
path, raw = sys.argv[1], sys.argv[2]
record = json.loads(raw)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, path)
PY
}

# Last line of preflight.txt is the verdict. <cdhash>, when given, must match
# the stamp preflight.sh wrote for that same run. CATCHER_NO_PREFLIGHT=1
# skips the check and marks the run ineligible for GREEN.
require_preflight_pass() {
  local report="$1"
  local want="${2:-}"
  if [[ "${CATCHER_NO_PREFLIGHT:-}" == "1" ]]; then
    export CATCHER_GREEN_ELIGIBLE=0
    echo "CATCHER_NO_PREFLIGHT=1: gate is running without a preflight. Not GREEN-eligible." >&2
    return 0
  fi
  if [[ -z "$report" || ! -f "$report" ]]; then
    echo "No passing preflight report. Run preflight first, or set CATCHER_PREFLIGHT_REPORT. CATCHER_NO_PREFLIGHT=1 skips this and is not GREEN-eligible." >&2
    return 1
  fi
  local last
  last="$(tail -n 1 "$report" | tr -d '\r')"
  if [[ "$last" != "PREFLIGHT RESULT PASS"* ]]; then
    echo "Preflight did not pass ($last). Not starting the gate." >&2
    return 1
  fi
  if [[ -n "$want" ]]; then
    local stamp got
    stamp="$(dirname "$report")/preflight_cdhash.txt"
    got="$(tr -d '[:space:]' < "$stamp" 2>/dev/null || true)"
    if [[ -z "$got" || "$got" != "$want" ]]; then
      echo "Preflight CDHash ${got:-missing} does not match ${want}." >&2
      return 1
    fi
  fi
}

# SIGKILL every leftover CatcherApp and every afplay of the known fixture.
# Survivors are a failed premise: the next launch would grade a stranger.
kill_orphans() {
  python3 "$ROOT/board.py" reap-orphans "$1"
}

# SIGTERM, then SIGKILL after the harness shutdown's live-tail budget.
# Prints `exited` or `killed` for the gate's rig_obs.json.
stop_catcher() {
  local session="$1"
  local pid=""
  if [[ -s "$session/catcher.pid" ]]; then
    pid="$(tr -cd '0-9' < "$session/catcher.pid")"
  fi
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' exited
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt 140 ]]; do
    sleep 0.25
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    printf '%s\n' killed
    return 0
  fi
  printf '%s\n' exited
}

# pfctl with no password prompt. Root calls the binary; anyone else uses
# `sudo -n` so a missing sudoers rule exits instead of waiting. Output is
# appended to PFCTL_LOG when that is set, and also written to stdout.
pfctl_run() {
  local status=0
  local out=""
  if [[ "$(id -u)" -eq 0 ]]; then
    out="$(/sbin/pfctl "$@" 2>&1)" || status=$?
  else
    out="$(sudo -n /sbin/pfctl "$@" 2>&1)" || status=$?
  fi
  if [[ -n "${PFCTL_LOG:-}" ]]; then
    {
      printf 'pfctl'
      printf ' %q' "$@"
      printf '\n%s\n' "$out"
    } >> "$PFCTL_LOG"
  fi
  printf '%s\n' "$out"
  return "$status"
}

volume_line() {
  if ! command -v osascript >/dev/null 2>&1; then
    printf '%s\n' "volume=not-observed muted=not-observed"
    return 0
  fi
  local volume muted
  volume="$(osascript -e 'output volume of (get volume settings)' 2>/dev/null || true)"
  muted="$(osascript -e 'output muted of (get volume settings)' 2>/dev/null || true)"
  printf 'volume=%s muted=%s\n' "${volume:-not-observed}" "${muted:-not-observed}"
}

afplay_ledger() {
  local session="$1"
  if [[ -n "${CATCHER_BOARD_RUN:-}" ]]; then
    printf '%s\n' "$CATCHER_BOARD_RUN/obs/afplay.log"
  else
    printf '%s\n' "$session/obs/afplay.log"
  fi
}

compile_window_probe() {
  local src="$ROOT/window_probe.swift"
  local bin="${TMPDIR:-/tmp}/catcher-window-probe"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    if ! swiftc -O -framework AppKit -o "$bin" "$src"; then
      return 1
    fi
  fi
  printf '%s\n' "$bin"
}

# Probe Catcher's window. Prints one token. --raise asks it to become front.
probe_window() {
  local session="$1"
  local raise="${2:-}"
  local pid=""
  if [[ -s "$session/catcher.pid" ]]; then
    pid="$(tr -cd '0-9' < "$session/catcher.pid")"
  fi
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' "NO_PROCESS"
    return 1
  fi
  local width height
  width="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["rigWindowMinWidth"]))' "$ROOT/thresholds.json")"
  height="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["rigWindowMinHeight"]))' "$ROOT/thresholds.json")"
  local helper
  helper="$(compile_window_probe)" || {
    printf '%s\n' "NO_HELPER"
    return 1
  }
  local -a args=("$pid" "$session")
  if [[ "$raise" == "--raise" ]]; then
    args+=(--raise)
  fi
  CATCHER_WINDOW_MIN_W="$width" CATCHER_WINDOW_MIN_H="$height" \
    CATCHER_APP="${CATCHER_APP:-}" "$helper" "${args[@]}"
}

# The only afplay entry. Refuses to play unless the probe prints RAISE OK.
# --prepare raises and records the ledger line without playing.
# --loop-guard re-probes without raising and does not rewrite rig_obs.json,
# so a loop that ends when the gate stops Catcher cannot erase a block tag.
play_fixture() {
  local session="$1"
  local mode="${2:-}"
  local ledger pid token status=0 volume
  ledger="$(afplay_ledger "$session")"
  mkdir -p "$(dirname "$ledger")"
  if [[ "$mode" != "--loop-guard" ]]; then
    wait_for_recording "$session" || {
      rig_obs_write "$session" '{"tag":"NO_RECORDING"}'
      return 1
    }
  fi
  pid=""
  if [[ -s "$session/catcher.pid" ]]; then
    pid="$(tr -cd '0-9' < "$session/catcher.pid")"
  fi
  if [[ "${CATCHER_RIG_FAULT:-}" == "kill-before-play" && "$mode" != "--loop-guard" && -n "$pid" ]]; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  local raise_flag=""
  if [[ "$mode" != "--loop-guard" ]]; then
    raise_flag="--raise"
  fi
  token="$(probe_window "$session" "$raise_flag")" || status=$?
  token="$(printf '%s\n' "$token" | tail -n 1 | tr -d '\r')"
  volume="$(volume_line)"
  if [[ "$token" != "RAISE OK" ]]; then
    printf '%s\n' "$token" >&2
    if [[ "$mode" != "--loop-guard" ]]; then
      rig_obs_write "$session" "$(python3 -c 'import json,sys; print(json.dumps({"tag": sys.argv[1]}))' "$token")"
    fi
    return 1
  fi
  local action="play"
  if [[ "$mode" == "--prepare" ]]; then
    action="prepare"
  fi
  printf 'wallMs=%s gate=%s pid=%s token=%s %s action=%s\n' \
    "$(wall_ms)" "${CATCHER_GATE:-unknown}" "$pid" "$token" "$volume" "$action" >> "$ledger"
  if [[ "$mode" == "--prepare" ]]; then
    return 0
  fi
  local started ended
  started="$(wall_ms)"
  afplay "$ROOT/fixtures/known-60s.wav"
  ended="$(wall_ms)"
  python3 - "$session/afplay_result.txt" "$pid" "$((ended - started))" "$volume" <<'PY'
import sys
from pathlib import Path
path, pid, wall, volume = sys.argv[1:]
Path(path).write_text(
    f"exit=0\npid={pid}\nwallMs={wall}\n{volume}\n",
    encoding="utf-8",
)
PY
}
