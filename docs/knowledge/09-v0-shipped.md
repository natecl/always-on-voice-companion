# v0 transcript foundation — shipped

What the green Mac run proved. The page is the transcript foundation only.

## What shipped

- ScreenCaptureKit keeps two tracks, `.audio` (system, "them") and `.microphone` ("me"). SCK delivers 48 kHz stereo float; the app downmixes and resamples to 16 kHz mono PCM16. [Two tracks, shipped](08-capture-layer.md#two-tracks-shipped).
- Reconnect: a socket stall goes `degraded`, the next socket opens without waiting for a parked `URLSession` close, backoff is 1, 2, 4, 8, 16 s then capped at 30 s, the new socket's origin carries `gap{fromMs,toMs}`, `resumed` waits until a post-resume final is queued (or the catch-up budget ends), and word times are rebased by `originMs`. [Reconnect path (shipped)](08-capture-layer.md#reconnect-path-shipped).
- `noAudio` uses AC RMS with DC removed, floor `rmsEpsilon = 0.05` (about −26 dBFS), a 300 ms speech hold, and a 10 s limit. A resting mic counts as silence, and the annotation fires even when zero frames arrived. P4 passing does not prove system audio was captured. P1's `system.pcm` peak/RMS and system `seg` text do. [noAudio detection (shipped)](08-capture-layer.md#noaudio-detection-shipped).

Not built: notes, Jev judgment in the pipeline, the judgment brief, interjection, the context graph, v1, and v2. `spike/` is the only Jev code, and it is on HOLD.

## Evidence

Mac run GREEN at `95837a8` (`95837a8891a07f4169ecfa9b869a7a80c4545ad3`): P1–P6 all `pass`, including P4 `noAudio`. Cap-reported. Board: `/tmp/catcher-auto/95837a8-20260923-003139/board.json` on the grading Mac, dated 2026-09-23 in that path. CDHash `62450598` (8 characters, as on the board). The board is not in git. `grade.json` is not committed.

P4 passing does not prove system audio was captured. P1's `system.pcm` peak/RMS and system `seg` text do.

Only a Mac `grade.json` or board with P1–P6 `pass` counts. Any later commit stays ungraded until the next Mac run.

Grading ran without a human in the loop. `cua-driver` drove the Mac UI (grants, gate prompts) and collected one `board.json`. The driver and the board schema are not in this repo.

## How it was graded

A LaunchServices-launched signed app runs the harness gates. `grade.py` writes one `grade.json` per gate. `cua-driver` collects those results into `board.json`.

`cua-driver` is Mac-side autonomous grade tooling, installed on Nathan's Mac for QA via Grok Bot and cua-driver. Scripts live under `/Users/n.chinlue/qa/catcher/`. It is not product code in `catcher/Sources`, and it does not ship inside the app bundle.

How to run a gate is [v0 grading](../qa/v0-grading.md). Pass conditions are only in that gate table.

## Process rules

Rules for the climbs after this one.

- **L1. One Cloud Agent climb at a time.** Cap unlocked parallel agents for the v0 foundation lock only. That unlock does not carry forward.
- **L2. One fix per QA cycle.** Each Mac run grades one change, so a red gate names one cause. The P3 reconnect fixes `8f4b110` through `005264d` landed one per commit, so each red Mac run pointed at one change.
- **L3. Fixtures change only on Cap GO.** `catcher/harness/fixtures/*` stays as committed until Cap says otherwise, so a grade is not mixed with an unreviewed wav.
- **L4. VM tests are not P1–P6.** A Linux `swift test` pass is reported as "not a Mac P-gate pass", never as green. The same is true of `macos-15` CI (`swift build` and `swift test`).

## Feature map

Feature map: TBD (`docs/FEATURE_MAP.md`, not authored here).

Related: [08-capture-layer.md](08-capture-layer.md) · [07-transcription.md](07-transcription.md) · [06-strategic-reads.md](06-strategic-reads.md) · [v0 grading](../qa/v0-grading.md)
