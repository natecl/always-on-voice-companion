#!/usr/bin/env bash
# Keyed 5× notes-model bake on the synthetic hour. Does not change the pin.
# The provisional pin stays grok-4.20-0309-non-reasoning until a Mac run's
# winner is reviewed by hand. This script never edits NotesService or thresholds.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?out dir}"
RUNS="${2:-5}"
export CATCHER_BRIEF=1
if [[ -z "${XAI_API_KEY:-}" ]]; then
  echo "b3_bake: XAI_API_KEY is unset. The keyed bake has not run, and the pin stays provisional." >&2
  exit 2
fi
MODELS="${CATCHER_BRIEF_BAKE_MODELS:-grok-4.20-0309-non-reasoning,grok-4-fast-non-reasoning,grok-4-1-fast-non-reasoning}"
PKG="$(cd "$ROOT/.." && pwd)"
mkdir -p "$OUT"
swift run --package-path "$PKG" BriefBench bake \
  "$PKG/harness/fixtures/known-60min.events.jsonl" \
  --out "$OUT" \
  --runs "$RUNS" \
  --models "$MODELS"
echo "b3_bake: review bake.json. The provisional pin is still grok-4.20-0309-non-reasoning; this script did not change it."
