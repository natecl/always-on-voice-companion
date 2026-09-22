#!/usr/bin/env bash
# Shared helpers. Launch through LaunchServices (`open`). A binary exec'd from a
# shell keeps the shell's app (Terminal, Cursor, iTerm) as its TCC responsible
# process: microphone status is read for that app, the Allow dialog names that
# app, and com.catcher.app never appears in the Microphone pane. `open --env`
# forwards the CATCHER_* variables and XAI_API_KEY; the same switches also go
# through `--args`.
set -euo pipefail

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
    echo "This open(1) has no --env. Falling back to a direct exec: TCC will bill the microphone to this terminal's app, not to com.catcher.app." >&2
    "$bin" "${args[@]}" &
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
