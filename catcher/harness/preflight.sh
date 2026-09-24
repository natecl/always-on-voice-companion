#!/usr/bin/env bash
# Preflight inside Catcher.app, launched through LaunchServices so TCC bills
# com.catcher.app. open(1) does not forward the app's exit status, so
# preflight.txt is the verdict.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"
SESSION="${1:-}"
if [[ -z "$SESSION" ]]; then
  echo "usage: $0 <session-root>" >&2
  exit 2
fi
mkdir -p "$SESSION"
REPORT="$SESSION/preflight.txt"
APP="${CATCHER_APP:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Set CATCHER_APP to the built Catcher.app." >&2
  printf 'PREFLIGHT signing FAIL error=missing-app source=harness\nPREFLIGHT RESULT FAIL failed=1 source=harness\n' > "$REPORT"
  cat "$REPORT"
  exit 1
fi
if ! require_stable_signature "$APP"; then
  printf 'PREFLIGHT signing FAIL source=harness\nPREFLIGHT RESULT FAIL failed=1 source=harness\n' > "$REPORT"
  cat "$REPORT"
  exit 1
fi
printf 'PREFLIGHT signing PASS source=harness\n' > "$REPORT"
# Same CDHash read as board-env: verbosity 4, then the CDHash= line.
# Lines the app writes do not carry source=harness.
python3 - "$ROOT" "$APP" "$SESSION/preflight_cdhash.txt" <<'PY'
import subprocess, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import board
app, dest = sys.argv[2], Path(sys.argv[3])
text = ""
try:
    sign = subprocess.run(board.codesign_cdhash_args(app), capture_output=True, text=True)
    text = (sign.stderr or "") + "\n" + (sign.stdout or "")
except OSError:
    text = ""
dest.write_text(board.cdhash_from_codesign(text) + "\n", encoding="utf-8")
PY

# The preflight Catcher only. ps shows CatcherApp.app even when the harness
# opened the Catcher.app symlink. Match either name, --preflight, and this
# session root so a different Catcher is left alone.
kill_preflight_app() {
  local session="$1"
  python3 - "$ROOT" "$session" <<'PY'
import os, signal, sys
sys.path.insert(0, sys.argv[1])
import board
session = sys.argv[2]
for pid, command in board.list_processes():
    if board.is_preflight_process(command, session):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
PY
}

export CATCHER_SESSION_ROOT="$SESSION"
export CATCHER_PREFLIGHT=1
args=(--preflight --session-root "$SESSION")
envs=(--env "CATCHER_SESSION_ROOT=$SESSION" --env "CATCHER_PREFLIGHT=1")
if [[ -n "${CATCHER_ENGINE:-}" ]]; then
  args+=(--engine "$CATCHER_ENGINE")
  envs+=(--env "CATCHER_ENGINE=$CATCHER_ENGINE")
fi
if [[ -n "${XAI_API_KEY:-}" ]]; then
  envs+=(--env "XAI_API_KEY=$XAI_API_KEY")
fi
# Do not pass -W. open -W returns only when the app exits, so a --preflight
# that never quits never reaches this poll.
set +e
if open --help 2>&1 | grep -q -- '--env'; then
  open -n "$APP" "${envs[@]}" --args "${args[@]}"
  launch_status=$?
else
  # Stock open(1) has no --env. Same LaunchServices path as launch_catcher.
  # There is no shell-exec fallback: TCC would bill this terminal's app.
  launch_via_workspace "$APP" "${args[@]}"
  launch_status=$?
fi
set -e
if [[ "$launch_status" -ne 0 ]]; then
  echo "LaunchServices failed to start $APP" >&2
  printf 'PREFLIGHT preflight-finish FAIL error=launch-failed source=harness\nPREFLIGHT RESULT FAIL failed=1 source=harness\n' >> "$REPORT"
  cat "$REPORT"
  exit 1
fi
# The app writes PREFLIGHT RESULT and terminates. Past the budget this is a
# hang, not a Screen Recording deny: kill only this preflight and say so.
LIMIT="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["rigPreflightTimeoutS"]))' "$ROOT/thresholds.json")"
deadline=$((SECONDS + LIMIT))
while [[ "$SECONDS" -lt "$deadline" ]]; do
  if [[ -f "$REPORT" ]] && tail -n 1 "$REPORT" | tr -d '\r' | grep -q '^PREFLIGHT RESULT '; then
    break
  fi
  sleep 0.1
done
if [[ ! -f "$REPORT" ]] || ! tail -n 1 "$REPORT" | tr -d '\r' | grep -q '^PREFLIGHT RESULT '; then
  kill_preflight_app "$SESSION"
  printf 'PREFLIGHT preflight-finish FAIL error=no-result source=harness\nPREFLIGHT RESULT FAIL failed=1 source=harness\n' >> "$REPORT"
  echo "preflight produced no RESULT within ${LIMIT}s. Wrote FAIL and stopped." >&2
fi
cat "$REPORT"
last="$(tail -n 1 "$REPORT" | tr -d '\r')"
if [[ "$last" == "PREFLIGHT RESULT PASS"* ]]; then
  exit 0
fi
exit 1
