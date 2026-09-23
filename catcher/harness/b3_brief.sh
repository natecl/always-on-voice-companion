#!/usr/bin/env bash
# B3: three live stops in one app run, then the 60-minute brief bench.
# v0 run.sh is not the entry point. P1–P6 stay on run.sh with notes off.
#
# Stop is cua click of recordButton when CATCHER_CUA is set, otherwise
# SIGUSR1 (stop and stay up). SIGTERM is sent only after the last brief.md
# and the bench. Copy is a cua click of copyNotesButton; without CATCHER_CUA
# the copy check cannot pass.
#
#   export CATCHER_APP=.../Catcher.app
#   export XAI_API_KEY=...
#   export CATCHER_CUA="/path/to/cua-click"   # optional; invoked as: "$CATCHER_CUA" <accessibilityIdentifier>
#   ./catcher/harness/b3_brief.sh /tmp/catcher-b3
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
SESSION="${1:?session root}"
mkdir -p "$SESSION"
export CATCHER_ENGINE=grok
export CATCHER_BRIEF=1
export CATCHER_NOTES_ENGINE=grok
export CATCHER_BRIEF_MODEL="${CATCHER_BRIEF_MODEL:-grok-4.20-0309-non-reasoning}"
if [[ -z "${XAI_API_KEY:-}" ]]; then
  echo "b3_brief: XAI_API_KEY is required. Notes stay off without it." >&2
  exit 2
fi

begin_harness_run "$SESSION" B3
launch_catcher "$SESSION" 1
wait_for_recording "$SESSION"

PARTS="$SESSION/b3-parts"
rm -rf "$PARTS"
mkdir -p "$PARTS"

click_identifier() {
  local ident="$1"
  if [[ -z "${CATCHER_CUA:-}" ]]; then
    return 1
  fi
  "$CATCHER_CUA" "$ident"
}

newest_session() {
  python3 - "$SESSION" <<'PY'
import os, sys
root = sys.argv[1]
found = []
for name in os.listdir(root):
    events = os.path.join(root, name, "events.jsonl")
    if os.path.isfile(events):
        found.append((os.path.getmtime(events), os.path.join(root, name)))
if not found:
    raise SystemExit(1)
found.sort()
print(found[-1][1])
PY
}

sha256_file() {
  if [[ ! -f "$1" ]]; then
    echo ""
    return 0
  fi
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

has_end() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
try:
    lines = open(path, encoding="utf-8")
except OSError:
    raise SystemExit(1)
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if row.get("t") == "end":
        raise SystemExit(0)
raise SystemExit(1)
PY
}

compile_probe() {
  local src="$ROOT/pasteboard_probe.swift"
  local bin="${TMPDIR:-/tmp}/catcher-pasteboard-probe"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    swiftc -O -framework AppKit -o "$bin" "$src"
  fi
  echo "$bin"
}

previous=""
index=1
while [[ "$index" -le 3 ]]; do
  if [[ "$index" -gt 1 ]]; then
    previous="$(newest_session)"
    if ! click_identifier recordButton; then
      echo "b3_brief: session $index needs CATCHER_CUA to click recordButton. Stopping after $((index - 1))." >&2
      break
    fi
    waited=0
    current=""
    while [[ "$waited" -lt 150 ]]; do
      current="$(newest_session || true)"
      if [[ -n "$current" && "$current" != "$previous" ]]; then
        break
      fi
      sleep 0.1
      waited=$((waited + 1))
    done
    if [[ -z "$current" || "$current" == "$previous" ]]; then
      echo "b3_brief: session $index did not start. Stopping after $((index - 1))." >&2
      break
    fi
  fi
  target="$(newest_session)"
  if command -v afplay >/dev/null 2>&1; then
    afplay "$ROOT/fixtures/known-60s.wav" || true
  fi
  sleep 2
  stop_sent="$(wall_ms)"
  if ! click_identifier recordButton; then
    kill -USR1 "$(cat "$SESSION/catcher.pid")"
  fi
  waited=0
  while [[ "$waited" -lt 100 ]]; do
    if has_end "$target/events.jsonl"; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  assembled="$(wall_ms)"
  events_sha="$(sha256_file "$target/events.jsonl")"
  session_sha="$(sha256_file "$target/session.json")"
  transcript_sha="$(sha256_file "$target/transcript.txt")"
  deadline=$((assembled + 35000))
  observed="$assembled"
  while [[ "$(wall_ms)" -lt "$deadline" ]]; do
    if [[ -s "$target/brief.md" ]]; then
      observed="$(wall_ms)"
      break
    fi
    sleep 0.1
  done
  if [[ ! -s "$target/brief.md" ]]; then
    observed="$(wall_ms)"
  fi
  paste_text=""
  probe_json='{"types":[],"html":""}'
  if click_identifier copyNotesButton; then
    sleep 0.4
    paste_text="$(pbpaste || true)"
    probe="$(compile_probe)"
    probe_json="$("$probe" || true)"
  fi
  python3 - "$PARTS/$index.json" "$target" "$stop_sent" "$observed" "$assembled" \
    "$events_sha" "$session_sha" "$transcript_sha" "$paste_text" "$probe_json" <<'PY'
import json, sys
path, directory, stop, observed, assembled, events, session, transcript, paste, probe = sys.argv[1:]
try:
    probed = json.loads(probe) if probe else {}
except json.JSONDecodeError:
    probed = {}
record = {
    "directory": directory,
    "stopSentWallMs": int(stop),
    "observedWallMs": int(observed),
    "assembledWallMs": int(assembled),
    "eventsSha256AtAssembled": events,
    "sessionJsonSha256AtAssembled": session,
    "transcriptSha256AtAssembled": transcript,
    "pbpaste": paste,
    "pasteboardTypes": probed.get("types") or [],
    "html": probed.get("html") or "",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle)
    handle.write("\n")
PY
  index=$((index + 1))
done

PKG="$(cd "$ROOT/.." && pwd)"
bench_json="$SESSION/b3b.json"
if ! swift run --package-path "$PKG" BriefBench \
  "$PKG/harness/fixtures/known-60min.events.jsonl" \
  --out "$SESSION/b3b" \
  --runs 3 >"$bench_json"; then
  echo "[]" >"$bench_json"
fi

python3 - "$SESSION/b3_observe.json" "$PARTS" "$bench_json" <<'PY'
import json, os, sys
out, parts, bench = sys.argv[1:]
sessions = []
if os.path.isdir(parts):
    for name in sorted(os.listdir(parts)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(parts, name), encoding="utf-8") as handle:
            sessions.append(json.load(handle))
try:
    runs = json.load(open(bench, encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    runs = []
if not isinstance(runs, list):
    runs = []
record = {"sessions": sessions, "long": {"runs": runs}}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
PY

if [[ -s "$SESSION/catcher.pid" ]]; then
  kill "$(cat "$SESSION/catcher.pid")" || true
fi
python3 "$ROOT/b3_grade.py" --root "$SESSION"
