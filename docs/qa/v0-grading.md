# v0 grading (P1–P6)

Catcher v0 is system audio + mic → transcription → a verified transcript on disk. This page is how QA runs that proof on a **physical Mac**. A Linux agent VM and the `macos-15` library CI cannot grant Screen Recording, play audio, or kill the network. Do not treat `swift test` or a missing `grade.json` as a pass.

v0 stays red until `v0-verdict.json` is `GREEN` for the SHA being claimed.

**Last hardened GREEN:** `b14e31a` (`b14e31a99a431e5cac6a49669f5c1955de38a1d1`) on 2026-09-23. CDHash `57250034b55e54e3ad6798983edf6e62c1553653`. Board `/tmp/catcher-auto/b14e31a-20260923-055848/board.json` on the grading Mac (not in git). Preflight and P1–P6 pass under the hardened verifier (soft-pass killed). This supersedes `95837a8` / CDHash `62450598` / board `/tmp/catcher-auto/95837a8-20260923-003139/board.json`. `MicrophoneGain` is on the mic path; the 0.05 `noAudio` floor is unchanged; held speech clears median ≥ 0.1000 (P6 p50 0.2039, micGainMax 16). A later commit stays ungraded until the next Mac run. Reconcile and merge stay with Cap/Nathan. Rows: [FEATURE_MAP.md](../FEATURE_MAP.md). Narrative: [09-v0-shipped.md](../knowledge/09-v0-shipped.md).

## Evidence tiers

| Tier | What | Counts for |
|---|---|---|
| **M** | `v0-verdict.json` with `"verdict": "GREEN"` for a SHA, produced on a Mac by `run.sh verdict` | The only v0 claim. "Mac GREEN @sha" means this file, with that `sha`. |
| **G** | One gate's `grade.json` with `result: pass` (provenance checked) | That gate on that SHA. "Fixed P3" needs Tier G for P3 on that SHA. |
| **L** | `swift test` (Linux VM or `macos-15` CI), `harness/tests` (`test_grade.py`, `test_verdict.py`), scripted or fake transports, including the `macParked` profile | Regression only. |

Tier L is never cited as P1–P6 evidence in a commit message, PR body, or status update.

## Result vocabulary

Each gate in `grade.json` is `{"result", "evidence", "checks"}`. `checks` is an ordered list of `{"name", "ok", "detail", "kind"}`. `result` is one of:

| Result | Meaning |
|---|---|
| `pass` | Every check passed **and** provenance says a Mac harness run of this build. The only result that counts. |
| `fail` | A product check failed. |
| `invalid` | The run did not set up the premise (P4 room not quiet, P3 block too short or resumed while `pf` was on). Not a pass and not a product failure: re-run. |
| `unproven` | The checks passed but provenance is missing or not a Mac harness run (graded on Linux, no `harness_run.json`, wrong gate, macOS < 15, `unknown` or `-dirty` or mismatched build SHA, session older than the harness start, no CDHash). **Never a pass.** |
| `n/a` | Not requested. |

A stub engine header on P1, P3, or P6 is `fail` ("stub engine cannot prove P1/P3/P6"). Numbers live in `catcher/harness/thresholds.json`; a Swift test fails if the verifier constants drift from it.

## One-time setup

1. macOS 15 or newer. Xcode with the macOS 15 SDK. [XcodeGen](https://github.com/yonaskolb/XcodeGen) on `PATH`. Python 3.
2. Build the app with the stable-signature script, not `swift run` and not an ad-hoc `xcodebuild`:

   ```bash
   cd catcher
   ./scripts/build-app.sh
   export CATCHER_APP="$PWD/build/Build/Products/Debug/Catcher.app"
   ```

   `build-app.sh` signs with `Catcher Development` (a local code-signing certificate it creates once) or with Apple Development when `CATCHER_DEVELOPMENT_TEAM` is set. The harness refuses `Signature=adhoc`. An ad-hoc cdhash changes every rebuild, so a grant cannot stick to the next binary. The designated requirement is the certificate plus `com.catcher.app`.
3. Launch `Catcher.app` once **through LaunchServices** — `open -n "$CATCHER_APP"` or a Finder double-click — and grant **Screen & System Audio Recording** and **Microphone** to bundle id `com.catcher.app`. Do not exec `Catcher.app/Contents/MacOS/CatcherApp` from a shell: TCC bills the shell's app (Terminal, Cursor, iTerm) as the responsible process, the status Catcher reads is that app's, the Allow dialog carries that app's name, and Catcher never appears in the Microphone pane. A grant given to Terminal or Xcode does not count, and P2 will grade the wrong binary. The Microphone pane has no +. Catcher appears there only after a real Allow or Deny for `com.catcher.app`. Launch asks for screen recording first; the microphone dialog comes only after that prompt is finished.

   If the window shows a red line under `BLOCKED`, read it: it is the same text as the Console line `Catcher mic authority …` and names the one fix. `audioInputEntitlement=false` with `hardenedRuntime=true` means the bundle was signed without `com.apple.security.device.audio-input`; rebuild with `build-app.sh` (it now fails a build like that). `ownsTCCIdentity=false responsible=Terminal` means it was started from a shell; press **Relaunch Catcher for microphone** or quit and use `open -n`. `status=notDetermined` means Allow can still appear; press **Request microphone** with Catcher in front. `status=denied` means Catcher has a denied row; Re-grant opens Privacy → Microphone where the toggle is. `status=authorized ownsTCCIdentity=true audioInputEntitlement=true` with any denied banner is a bug — copy the Console line and the banner into the report. Quit Zoom before retrying; a call can suppress Allow.
4. `export XAI_API_KEY=...` for any gate that uses Grok (`P1`, `P3`, `P6`). `CATCHER_ENGINE=grok` is the default. `CATCHER_ENGINE=stub` forces the deterministic engine.
5. Run preflight before P1. Do not start P1 on a FAIL line; the fix on that line is the next action.

   ```bash
   ./catcher/harness/run.sh preflight /tmp/catcher-pre
   ```

   The command exits 0 only when `/tmp/catcher-pre/preflight.txt` ends in `PREFLIGHT RESULT PASS`. Checks, the sample stage log, and how to read a failure are in [`v0-diagnostics.md`](v0-diagnostics.md).
6. Replace `catcher/harness/fixtures/known-60s.wav` with a clear ~60 s reading of `known-60s.ref.txt` before scoring P1. The file in git is a 16 kHz mono PCM16 carrier so the script has something to play. It is not that reading. WER against the reference will fail until you replace it.

## How a run is laid out

```bash
./catcher/harness/run.sh p1 /tmp/catcher-p1
```

The path you pass is `CATCHER_SESSION_ROOT`. The app creates one directory per recording:

```text
/tmp/catcher-p1/<uuid>/
  events.jsonl          session / seg / ann / end
  transcript.txt        [me] and [them] lines
  session.json          clean, recovered, segmentCount, engine
  system.pcm            raw PCM16, only because the harness sets CATCHER_HARNESS=1
  microphone.pcm
  stages.log            stage checkpoints; grade.py does not read this
  grade.json            written by harness/grade.py
  ../harness_run.json   provenance, written before launch (below)
  ../catcher.pid        pid of the app binary, next to the uuid directory
  ../live_session       absolute path of the first recording (harness only)
  ../revoke_session     P2: that path, copied before tccutil reset
  ../revoke_wall_ms     P2 only, wall-clock milliseconds (also revokeWallMs in harness_run.json)

<out>/v0-verdict.json   run.sh verdict: six gates re-graded, GREEN or RED
```

`harness_run.json` holds `gate`, `startedWallMs`, `host`, `macOS` (`sw_vers`), `arch`, `hwModel`, `catcherApp`, `codesign` (`cdhash`, `teamIdentifier`, `signature`, `authority`), `catcherGitSHA` (the app's Info.plist, stamped by `build-app.sh`), `catcherEngine`, and `harnessGitSHA`. Gate scripts add `revokeWallMs` (P2) and `pfOnWallMs` / `pfOffWallMs` (P3). The session header `app` is `0.0.1+<sha>`; `grade.py` requires it to equal `catcherGitSHA`. The file proves "ran through this harness on a Mac", not tamper-proofing.

`run.sh` resolves the newest child that contains `events.jsonl` and grades that directory, except P2. P2 grades `revoke_session` (the recording that was live at the reset), not a later session whose only `blocked` ann is at `atMs=0` from a failed `startCapture`. Default sessions outside the harness go to `~/Library/Application Support/Catcher/sessions/<uuid>/` with the same file names and no PCM unless `CATCHER_HARNESS=1`.

The harness starts `Catcher.app` through LaunchServices (bundle id `com.catcher.app`, not an ad-hoc side binary, and verified to carry the `com.apple.security.device.audio-input` entitlement). Stock `open` has no `--env`, so the harness compiles `launch_services.swift` and calls `NSWorkspace.openApplication`, passing the shell environment through (`CATCHER_SESSION_ROOT`, `CATCHER_HARNESS`, `CATCHER_ENGINE`, `CATCHER_AUTO_RECORD`, `XAI_API_KEY`) and the same switches as `--session-root`, `--harness`, `--engine`, and `--auto-record`. It does not exec the binary from the shell: that would bill microphone access to Terminal. The app writes `catcher.pid` itself once it is up, and `lib.sh` waits for that file. A non-zero gate prints two `TRACE` lines from that session's `stages.log` and then exits with the gate's status. `stages.log` does not grade anything: `grade.py` never reads it, and a `STAGE` line cannot pass or fail P1–P6.

After a P1 run, `system.pcm` in the session directory is the capture proof. It is absent when no `PCMFrame` was emitted. A file of the right length that is all zeros is still a failed capture: `afplay` of the fixture must show a non-zero peak and RMS, and system `seg` rows must have text. The microphone track can look healthy at the same time; that does not prove the system track.

CI (`.github/workflows/catcher-ci.yml`) has two Tier L jobs: `library-tests-not-p1-p6` (`swift build` and `swift test` on `macos-15`) and `harness-grader` (`python3 -m unittest discover -s catcher/harness/tests` on `ubuntu-latest`). Neither produces `grade.json` or a verdict.

## Gates

| Gate | What you do | Pass (every check; see `grade.json` `checks`) |
|---|---|---|
| **P1** | `run.sh p1 <dir>` plays the fixture, `kill -9`s the app, relaunches so crash recovery runs, then grades. Always Grok. | Header engine is Grok. System-track WER ≤ 15 % against `known-60s.ref.txt`. No >2 s hole in system speech (AC RMS windows of `system.pcm` over 0.001, so DC offset is not speech). A recovered session. No `noAudio` whose 10 s window holds sustained speech in either PCM. |
| **P2** | `CATCHER_ALLOW_TCC_RESET=1 run.sh p2 <dir>`. The script runs `tccutil reset ScreenCapture com.catcher.app` and waits for you to re-grant. The score is the session that was recording at the reset. | An `ann` with `kind: blocked` on that live session within 2 s of the revoke, and no `seg` after that timestamp. |
| **P3** | As root, `CATCHER_ALLOW_PF=1 run.sh p3 <dir>`. The fixture loops from launch. `api.x.ai:443` is blocked for 15 s and `pfOnWallMs` / `pfOffWallMs` are recorded. No enter: the script waits for `resumed track=system`, then records `backlogMs` + 3 s + 20 s more. | Grok header. Per track (system required; microphone when it has a gap): a `gap` spanning ≥ 10 s (shorter is `invalid`); a `degraded` with that `track=` within 12 s of `pf` on (startup or heartbeat degrades do not count); `degraded` < `gap` < `resumed track=<t>` in file order, the gap covering the block; `resumed` after `pf` off (while `pf` was on is `invalid`) and within 45 s; ≥ 10 words of system `seg` starting at `resumed.atMs + backlogMs + 3 s` (earlier segs are replayed backlog and do not count); no degrade or gap left open after resume; the session runs ≥ 20 s past live. |
| **P4** | Mute output, stay quiet, `run.sh p4 <dir>` (16 s run). | A `noAudio` with `atMs` within 10 s of capture start (`observedFromMs`); its `emittedAtMs` no later than that + 1.5 s; not the `no frames` path and both PCM files covering capture start to emission (a dead capture fails); no non-blank `seg` and no "audio is flowing" heartbeat before emission. Sustained audio in either PCM (AC RMS over 0.025) or system AC RMS over 0.001 is `invalid`: the room was not quiet or output was not muted. |
| **P5** | `run.sh p5 <stub-dir> <grok-session-dir>`. Forces `CATCHER_ENGINE=stub` and replays the fixture. `verdict` uses the P1 session as the reference. | Header engine `stub`. JSONL row types and keys match the schema and the reference's shape. The reference is a Grok session from the same build SHA. Transcript text is not compared. |
| **P6** | `run.sh p6 <dir>` while you talk over the fixture at normal conversational volume, arm's length. | Grok header. At least one `seg` on `microphone` and one on `system`, a non-null `speaker` on a system `seg`, no `noAudio` over sustained speech, and median mic speech AC RMS ≥ 2 × the 0.05 `noAudio` floor. Evidence always prints mic p10/p50/p90 (calibration data for the floor). `microphone.pcm` is recorded after the app's microphone gain (`MicrophoneGain`: held speech toward −14 dBFS, at most +24 dB, unity on room tone); `stages.log` `pcm-extract` reports `micGain`/`micGainMax`. |

P2 and P3 refuse to touch TCC or the packet filter unless the matching `CATCHER_ALLOW_*` variable is `1`.

Score one session by hand:

```bash
python3 catcher/harness/grade.py --session <uuid-dir> --gate P1 \
  --ref catcher/harness/fixtures/known-60s.ref.txt --expect-recovery
python3 catcher/harness/wer.py --ref catcher/harness/fixtures/known-60s.ref.txt \
  --hyp <uuid-dir>/transcript.txt
```

`grade.py` exits 0 only when every requested gate is `pass`. Unrequested gates are `n/a`. A truncated last line of `events.jsonl` is ignored, matching crash recovery. `--no-provenance` exists for unit tests only and forces `unproven`.

## Verdict

After the six gates, on the same Mac and the same build:

```bash
./catcher/harness/run.sh verdict /tmp/catcher-verdict \
  --p1 /tmp/catcher-p1 --p2 /tmp/catcher-p2 --p3 /tmp/catcher-p3 \
  --p4 /tmp/catcher-p4 --p5 /tmp/catcher-p5 --p6 /tmp/catcher-p6
```

`verdict.py` re-grades each root (it does not trust a `grade.json` on disk) and writes `v0-verdict.json` with `verdict`, `sha`, `cdhash`, `reasons`, per-gate results, `gradedOn`, and `gradedAt`. `GREEN` requires all six `pass`, one `CatcherGitSHA` and one `CDHash` across them, and a P5 reference that is the same build's Grok session. It exits 0 only on `GREEN`.

## What a pass is not

`swift test` passing, a stub session, a single gate's `grade.json`, or this document existing does not grade v0. QA copies `v0-verdict.json` from the Mac that ran the six gates. Until it says `GREEN` for the SHA, v0 is red.
