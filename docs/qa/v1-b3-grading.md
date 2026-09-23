# v1 B3 grading — notes after stop

B3 is the proof that a stopped session becomes shareable notes within 30 seconds. This page is how QA runs that proof on a **physical Mac**. A Linux agent VM cannot grant Screen Recording, play the fixture, or call xAI. `swift test` and `harness/tests/test_b3_grade.py` are Tier L. They are not a B3 pass.

B3 stays ungraded until `<dir>/grade.json` has `B3.result: pass` **and** `run.sh verdict` writes `v0-verdict.json` `GREEN` for the **same SHA and CDHash**. FEATURE_MAP does not flip on this document alone.

The model id `grok-4.20-0309-non-reasoning` is a **provisional pin**. The keyed 5× bake has not been scored. Do not treat the pin as a bake-off winner.

## What you run

v0 `run.sh` is unchanged. B3 is a separate script so P1–P6 stay on today's path (notes off unless `CATCHER_BRIEF=1`).

```bash
export CATCHER_APP="$PWD/catcher/build/Build/Products/Debug/Catcher.app"
export XAI_API_KEY=...
export CATCHER_CUA="/path/to/cua-click"   # optional; see below
./catcher/harness/b3_brief.sh /tmp/catcher-b3
```

The script exports `CATCHER_BRIEF=1`, `CATCHER_ENGINE=grok`, and `CATCHER_NOTES_ENGINE=grok`. It launches through the same LaunchServices helper as v0. It does not exec the binary from the shell.

Keyed bake, separate from the grade (it does not edit the pin):

```bash
export XAI_API_KEY=...
export CATCHER_BRIEF=1
./catcher/harness/b3_bake.sh /tmp/catcher-b3-bake 5
```

That is `brief-bench bake` on `catcher/harness/fixtures/known-60min.events.jsonl` for 5 runs of at most three model ids. Review `/tmp/catcher-b3-bake/bake.json`. The provisional pin stays until someone updates `NotesService.briefModel` on purpose.

## One app run

`b3_brief.sh` does this:

1. Write `<dir>/harness_run.json` with `"gate": "B3"` before launch.
2. Launch with auto-record. Play `known-60s.wav`.
3. Stop without quitting. If `CATCHER_CUA` is set, `"$CATCHER_CUA" recordButton`. Otherwise `SIGUSR1` (stop and stay up, only because the app was launched with `CATCHER_HARNESS=1` and `CATCHER_BRIEF=1`). `stopSentWallMs` is recorded immediately before that stop.
4. When `events.jsonl` contains `end`, hash `events.jsonl`, `session.json`, and `transcript.txt`, and record `assembledWallMs`.
5. Poll every 100 ms for `brief.md`. Record `observedWallMs`.
6. If `CATCHER_CUA` is set, `"$CATCHER_CUA" copyNotesButton`, then `pbpaste` and `pasteboard_probe.swift` (pasteboard type names plus the HTML body).
7. Repeat until three sessions exist. Sessions 2 and 3 start with `"$CATCHER_CUA" recordButton`. Without `CATCHER_CUA` the script cannot start them; the grade is `invalid` (re-run), not a pass.
8. `brief-bench` runs the same fixture for 3 stage timings (`<dir>/b3b.json`).
9. `SIGTERM` the app, then `b3_grade.py` writes `<dir>/grade.json`.

`CATCHER_CUA` is invoked with one argument, the accessibility identifier (`recordButton` or `copyNotesButton`). Point it at the Mac cua-driver wrapper. The driver itself is not in this repo.

## Gate table

`<dir>/grade.json` is `{"B3": {"result", "evidence", "checks"}}`. `result` uses the v0 words.

| Check | Pass | Otherwise |
|---|---|---|
| `latency` | For all 3 live sessions, `observedWallMs − stopSentWallMs ≤ 30000`. The check grades the max and reports p50. | `fail` |
| `long` | `max(B3b totalMs) + max(stopSent → assembledWallMs) ≤ 30000`. `totalMs` is the brief-bench stage. | `fail` |
| `schema` | `brief.json` is `catcher.brief/1`, `cost` is null, a `summary` block is present, and there is at least one item. | `fail` |
| `cites` | At least one item has a cite, and every cite is a final `seg.seq` in `events.jsonl`. | `fail` |
| `shareable` | `brief.md` is non-empty and equals the reference renderer (footer `Notes by Catcher`, caveats omitted). | `fail` |
| `copy` | `pbpaste` equals `brief.md`, and `public.html` is on the pasteboard. When the probe captured HTML, it equals the reference HTML. | `fail` |
| `untouched` | `sha256(events.jsonl)` equals `source.eventsSha256` and the assembled hashes of `events.jsonl`, `session.json`, and `transcript.txt`. The brief never writes `events.jsonl`. | `fail` |
| `engine` | The transcript header engine is Grok (`thresholds.json` `grokEngine`). The notes engine name is not `stub`. | `fail` |
| `provenance` | Same rules as v0 `grade.py`: graded on a Mac, macOS ≥ 15, `harness_run.json` gate `B3`, signed (not ad-hoc), header SHA matches `CatcherGitSHA`, session newer than the harness start. | `unproven` |
| 3 sessions and 3 bench runs | The observe file has both. | `invalid` (the harness did not finish the protocol) |
| network down | `brief.md` is missing and `brief-error.json` names a transport, timeout, or missing-key error. The loud failure is the error file. | `invalid` (re-run, not a product fail) |

A stub engine cannot prove B3. `--no-provenance` exists for `test_b3_grade.py` only and forces `unproven`.

`b3LatencyMs` is 30000 in `b3_grade.py`. It is not in v0 `thresholds.json`.

## After B3

On the same Mac and the same build, re-run preflight and P1–P6:

```bash
./catcher/harness/run.sh verdict /tmp/catcher-p1 /tmp/catcher-p2 /tmp/catcher-p3 /tmp/catcher-p4 /tmp/catcher-p5 /tmp/catcher-p6
```

v0 gates do not set `CATCHER_BRIEF`. Notes stay off, which is what keeps P1–P6 on the previous path.

Arm B3 only when this page's script is what you run, the keyed bake command above is the bake you run, and the v0 verdict is the regression you run beside it. A pass still requires the Mac artifacts. This repository does not contain them yet.
