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
# The stamp the gate guard compares. Lines the app writes do not carry
# source=harness, so a board can tell the two apart.
codesign -dv "$APP" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1 > "$SESSION/preflight_cdhash.txt"

# The preflight Catcher only. Match the app binary, --preflight, and this
# session root so a different CatcherApp is left alone.
kill_preflight_app() {
  local app="$1"
  local session="$2"
  local bin="$app/Contents/MacOS/CatcherApp"
  python3 - "$bin" "$session" <<'PY'
import os, signal, subprocess, sys
binary, session = sys.argv[1], sys.argv[2]
try:
    listed = subprocess.run(["ps", "-ax", "-o", "pid=", "-o", "command="], capture_output=True, text=True, check=False)
except OSError:
    raise SystemExit
for line in listed.stdout.splitlines():
    stripped = line.strip()
    if not stripped:
        continue
    pid_text, _, command = stripped.partition(" ")
    if binary in command and "--preflight" in command and session in command:
        try:
            os.kill(int(pid_text), signal.SIGKILL)
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
  kill_preflight_app "$APP" "$SESSION"
  printf 'PREFLIGHT preflight-finish FAIL error=no-result source=harness\nPREFLIGHT RESULT FAIL failed=1 source=harness\n' >> "$REPORT"
  echo "preflight produced no RESULT within ${LIMIT}s. Wrote FAIL and stopped." >&2
fi
cat "$REPORT"
last="$(tail -n 1 "$REPORT" | tr -d '\r')"
if [[ "$last" == "PREFLIGHT RESULT PASS"* ]]; then
  exit 0
fi
exit 1
