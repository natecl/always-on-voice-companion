#!/usr/bin/env bash
# Block api.x.ai for 15s mid-session. Requires root and CATCHER_ALLOW_PF=1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session dir}"
mkdir -p "$SESSION"
if [[ "${CATCHER_ALLOW_PF:-}" != "1" ]]; then
  echo "Refusing to change the packet filter. Re-run as root with CATCHER_ALLOW_PF=1." >&2
  exit 2
fi
export CATCHER_ENGINE=grok
begin_harness_run "$SESSION" P3
launch_catcher "$SESSION" 1
sleep 3
IPS="$(dig +short api.x.ai A | tr '\n' ' ')"
if [[ -z "$IPS" ]]; then
  echo "dig did not resolve api.x.ai" >&2
  exit 1
fi
RULE="$(mktemp)"
{
  echo "table <catcher_xai> { $IPS }"
  echo "block drop out proto tcp from any to <catcher_xai> port 443"
} > "$RULE"
pfctl -a catcher -f "$RULE"
sleep 15
pfctl -a catcher -F all || true
rm -f "$RULE"
echo "Network restored. Leave the session running until Catcher reconnects (backoff is 1, 2, 4, then 8s), then press enter."
read -r _
kill "$(cat "$SESSION/catcher.pid")" || true
TARGET="$(resolve_session "$SESSION")"
python3 "$ROOT/grade.py" --session "$TARGET" --gate P3
