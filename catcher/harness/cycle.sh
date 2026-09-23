#!/usr/bin/env bash
# Meta cycle. Preflight first. Anything other than PREFLIGHT RESULT PASS writes
# board.json and returns. P1–P6 are not launched and afplay is not started.
# A tcc-screen FAIL is a host wall: Cap re-arms after Nathan re-grants.
# It is not a soft-pass.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

# QA supplies non-interactive stdin for p2 and p4. This script does not.
run_cycle_gates() {
  local run="$1"
  local status=0
  local gate
  for gate in p1 p2 p3 p4 p6; do
    mkdir -p "$run/$gate"
    if ! "$ROOT/run.sh" "$gate" "$run/$gate"; then
      status=1
    fi
  done
  mkdir -p "$run/p5"
  if ! "$ROOT/run.sh" p5 "$run/p5" "$run/p1"; then
    status=1
  fi
  return "$status"
}

cycle_main() {
  local run="${1:?run dir}"
  local pre="${CATCHER_PREFLIGHT_DIR:-$run/preflight}"
  mkdir -p "$pre"
  local report="$pre/preflight.txt"
  if [[ "${CATCHER_SKIP_PREFLIGHT_LAUNCH:-}" != "1" ]]; then
    set +e
    "$ROOT/run.sh" preflight "$pre"
    set -e
  fi
  if ! preflight_is_pass "$report"; then
    write_preflight_board "$run" "$report"
    echo "preflight FAIL; cycle stopped. No P1–P6 and no afplay. Board: $run/board.json" >&2
    return 1
  fi
  run_cycle_gates "$run"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cycle_main "$@"
fi
