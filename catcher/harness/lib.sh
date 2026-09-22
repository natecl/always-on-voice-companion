#!/usr/bin/env bash
# Shared helpers. Launch the signed app binary directly so CATCHER_* env vars
# reach the process. `open` starts a GUI session that does not inherit them.
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
}

# Direct-exec the bundle binary so XAI_API_KEY and the signature stay with com.catcher.app.
# The same flags are passed as arguments because `open` drops the environment.
launch_catcher() {
  local session="$1"
  local auto="${2:-1}"
  local bin
  bin="$(catcher_bin)"
  export CATCHER_SESSION_ROOT="$session"
  export CATCHER_HARNESS=1
  local -a args=(--session-root "$session" --harness)
  if [[ -n "${CATCHER_ENGINE:-}" ]]; then
    args+=(--engine "$CATCHER_ENGINE")
  fi
  if [[ "$auto" == "1" ]]; then
    export CATCHER_AUTO_RECORD=1
    args+=(--auto-record)
  fi
  "$bin" "${args[@]}" &
  echo $! > "$session/catcher.pid"
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
