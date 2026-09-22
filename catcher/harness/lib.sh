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
    echo "Missing executable $bin. Build with xcodebuild after xcodegen." >&2
    return 2
  fi
  echo "$bin"
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
