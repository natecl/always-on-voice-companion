# v1 Phase 1 grading (B2, B4) — S0 baseline

How QA measures the live loop on a **physical Mac**. This page is the S0 measurement runbook. A Linux agent VM and the `macos-15` library CI cannot grant Screen Recording, play audio, or click the Record button. `swift test` and `harness/tests/test_grade_v1.py` are Tier L. They do not fill the baseline table below, and they are not a B2 or B4 pass.

S0 is the probe and the grader. It does not claim the bars. LV1–LV3 and ST1–ST5 are not in this build.

Plan: [v1-phase1-live.md](../plans/v1-phase1-live.md). Brief: [v1-better.md](../briefs/v1-better.md). v0 gates are unchanged and still run from [v0-grading.md](v0-grading.md).

## What S0 built, and what it left locked

| Cap-call | In this build |
|---|---|
| B2: p95 lag ≤ 2 s over ≥ 100 system fixture words, anchor = word end, words before `live` reported as `startBacklog` and not graded | Graded by `grade_v1.py` |
| B4: cold = process not running, grants already in place. `live` = both tracks have delivered a frame and both engines have reached `streaming`. 5 runs | `cold-record` is launch + Record click. Five separate directories |
| Hotkey ⌃⌥⌘R, launch at login off, start = hotkey and orb | Locked. Not built (ST2, ST4, ST3) |
| Skip the idle launch permission probe when grants are already authorized | Locked. Not built (ST4). This build still opens a real stream at every launch |
| `--auto-record` is a no-op without `--harness` | Locked. Not built (ST1). A harness launch still auto-records, and the sidecar labels it `harnessAutoRecord` |
| `latency.jsonl` is harness-only. `events.jsonl` stays the v0 schema | Built. A sidecar write failure is logged once and does not fail the session |

`run.sh`, `grade.py`, `verdict.py`, and `thresholds.json` are not modified. v1 grading is new files that import `grade.py`.

## Evidence tiers

| Tier | What | Counts for |
|---|---|---|
| **M** | Not produced by S0. The phase verdict script arrives when B2 and B4 are being closed | The only future Phase 1 claim |
| **G** | `grade_v1.json` with `result: pass` for B2 or one B4 scenario, provenance checked | That bar on that SHA. S0 does not expect `pass` |
| **L** | `swift test`, `python3 -m unittest discover -s catcher/harness/tests` | Regression only. Never cite as B2, B4, or P1–P6 |

Result vocabulary matches v0: `pass`, `fail`, `invalid`, `unproven`, `n/a`. Off a Mac, a clean synthetic session is `unproven`. A `gap` ann makes B2 `invalid` (word times after a reconnect are not graded).

## One-time setup

Same machine and grants as [v0 grading](v0-grading.md): macOS 15+, `Catcher.app` built by `catcher/scripts/build-app.sh`, `CATCHER_APP` set, Screen & System Audio Recording and Microphone already granted to `com.catcher.app`, `XAI_API_KEY` set. Replace `catcher/harness/fixtures/known-60s.wav` with the same real reading P1 uses. Do not change the file in git (L3).

The click tool posts a `CGEvent`. The process that runs the harness (Terminal, or whatever launches `input_events`) needs Accessibility, or the click is dropped and B4 measures a gesture that never happened. One human press of Record, noted in the table, is the check that the synthetic click and a real click agree.

## B2 — partials behind speech

```bash
./catcher/harness/run_v1.sh b2 /tmp/catcher-b2
```

The script launches with `--harness --auto-record` (source `harnessAutoRecord`), waits for the `live` mark, stamps `playWallMs`, plays `known-60s.wav`, sends SIGTERM (clean stop, not `kill -9`), and writes `/tmp/catcher-b2/<uuid>/grade_v1.json`.

`grade_v1.py --gate B2` checks:

| Check | Pass |
|---|---|
| provenance | Darwin, harness gate `B2`, macOS ≥ 15, header sha matches `CatcherGitSHA`, session after harness start, non-ad-hoc CDHash |
| `engine=grok` | header engine is Grok |
| `no-gap` | no `gap` ann, else `invalid` |
| `sidecar-present` | `clock`, `start`, and `live` rows exist, and every system `tx` row has a `ui` row |
| `start-source` | the one `start` row is `harnessAutoRecord` |
| `graded-words` | ≥ 100 system-track words from final rows whose audio end is after `live`. Earlier words are `startBacklog` |
| `lag-p95` | p95 of `shownAtMs − capAtMs` ≤ 2000. `capAtMs` is the frame that contains the word's end. Evidence includes p50, p95, max, and the capture→sent, sent→recv, recv→shown hops |
| `first-word-external` | first system partial's wall time ≤ `playWallMs` + wav onset + that word's duration + 2000. Onset is the first 100 ms window of the wav with mean-removed RMS ≥ `speechEvidenceRmsFloor` |
| `captured-for-real` | `system.pcm` has a non-zero sample and a system `seg` has text |

`sentAtMs` is the time `engine.send` returned. A short tail still sitting in the engine's chunk buffer is stamped as sent. The hop is a hint, not the bar.

## B4 — cold via the Record button

Quit Catcher first. The script refuses to start when `CatcherApp` is already running.

```bash
for n in 1 2 3 4 5; do
  ./catcher/harness/run_v1.sh b4 /tmp/catcher-b4-cold-$n cold-record
done
```

Each run stamps launch, waits until the launch probe has finished (`ui_ready`) and the Record button has a frame, samples `lsof` for sockets, clicks Record, waits for `live`, plays 8 s of the fixture, clicks Record again to stop, and writes `grade_v1.json`.

t0 is the launch stamp. The 5 s bar includes process start, the launch permission probe, the click, and arming. This build still opens a real capture stream during that probe, so the number is expected to be large. That is the baseline ST4 is supposed to move.

`warm-hotkey`, `warm-orb`, and `cold` (orb, two inputs) exit 2. Those inputs are not in this build.

| Check | Pass |
|---|---|
| provenance | harness gate `B4-cold-record`, same rules as B2 |
| `engine=grok` | header engine is Grok |
| `inputs≤2` | exactly launch + one `recordButton` at or before `live`. The stop click is after `live` and does not count |
| `no-session-before-input` | the session's `startedAt` is not more than 0.5 s before the Record click, and no other session directory exists |
| `idle-no-socket` | the `lsof` sample taken after launch and before the click does not mention `api.x.ai` |
| `single-start` | one `start` row, source `recordButton` |
| `live-honest` | `live` is at or after both `first-frame` marks and both `streaming` marks |
| `live-within` | `live` wall − launch wall ≤ 5000 ms |
| `captured-for-real` | same as B2 |
| `stopped-by-input` | `stop-requested` source is `recordButton` and the `end` row is `clean: true` |

Five `pass` results are required before B4 can be called green. S0 records whatever came back.

## v0 still has to be green on this SHA

S0 touches the pipeline and the app. Before anyone treats the SHA as safe to build on, QA runs the unchanged v0 harness:

```bash
./catcher/harness/run.sh preflight /tmp/catcher-pre
./catcher/harness/run.sh p1 /tmp/catcher-p1
./catcher/harness/run.sh p2 /tmp/catcher-p2
./catcher/harness/run.sh p3 /tmp/catcher-p3
./catcher/harness/run.sh p4 /tmp/catcher-p4
./catcher/harness/run.sh p5 /tmp/catcher-p5 /tmp/catcher-p1
./catcher/harness/run.sh p6 /tmp/catcher-p6
./catcher/harness/run.sh verdict /tmp/catcher-verdict \
  --p1 /tmp/catcher-p1 --p2 /tmp/catcher-p2 --p3 /tmp/catcher-p3 \
  --p4 /tmp/catcher-p4 --p5 /tmp/catcher-p5 --p6 /tmp/catcher-p6
```

P2 and P3 still need their `CATCHER_ALLOW_*` switches. Copy the short SHA, CDHash, and `v0-verdict.json` verdict into the baseline table. A v0 row in [FEATURE_MAP.md](../FEATURE_MAP.md) changes only when that Mac run changes it.

## Baseline record

Not measured. The climb that added this page ran on a Linux VM. It cannot launch `Catcher.app`, play audio, or write `grade_v1.json` / `v0-verdict.json`. Do not read empty cells as a pass, a fail, or a number.

| Run | SHA | CDHash | grade_v1 / v0-verdict | p50 | p95 | max | hops (capture→sent / sent→recv / recv→shown) | live − launch | Notes |
|---|---|---|---|---|---|---|---|---|---|
| B2 | | | not run | | | | | | |
| B4 cold-record 1 | | | not run | | | | | | |
| B4 cold-record 2 | | | not run | | | | | | |
| B4 cold-record 3 | | | not run | | | | | | |
| B4 cold-record 4 | | | not run | | | | | | |
| B4 cold-record 5 | | | not run | | | | | | |
| v0 preflight + P1–P6 | | | not run | | | | | | |

QA fills a row from that run's `grade_v1.json` evidence line (`p50`, `p95`, `max`, the three hops, `startBacklog`) or from `live-within`'s millisecond delta. The v0 row is the `verdict` field of `v0-verdict.json`.
