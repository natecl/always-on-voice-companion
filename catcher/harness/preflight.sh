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
  printf 'PREFLIGHT signing FAIL error=missing-app\nPREFLIGHT RESULT FAIL failed=1\n' > "$REPORT"
  cat "$REPORT"
  exit 1
fi
if ! require_stable_signature "$APP"; then
  printf 'PREFLIGHT signing FAIL\nPREFLIGHT RESULT FAIL failed=1\n' > "$REPORT"
  cat "$REPORT"
  exit 1
fi
printf 'PREFLIGHT signing PASS\n' > "$REPORT"

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
set +e
if open --help 2>&1 | grep -q -- '--env'; then
  open -n -W "$APP" "${envs[@]}" --args "${args[@]}"
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
  exit 1
fi
# open -W waits for exit. NSWorkspace returns at launch, so poll either way.
# The app fsyncs preflight.txt and then terminates. The file is the verdict.
waited=0
while [[ "$waited" -lt 600 ]]; do
  if [[ -f "$REPORT" ]] && tail -n 1 "$REPORT" | grep -q '^PREFLIGHT RESULT '; then
    break
  fi
  sleep 0.1
  waited=$((waited + 1))
done
if [[ ! -f "$REPORT" ]]; then
  echo "Catcher did not write $REPORT" >&2
  exit 1
fi
cat "$REPORT"
last="$(tail -n 1 "$REPORT" | tr -d '\r')"
if [[ "$last" == "PREFLIGHT RESULT PASS"* ]]; then
  exit 0
fi
exit 1
