# v0 grading (P1–P6)

Catcher v0 is system audio + mic → transcription → a verified transcript on disk. This page is how QA runs that proof on a **physical Mac**. A Linux agent VM and the `macos-15` library CI cannot grant Screen Recording, play audio, or kill the network. Do not treat `swift test` or a missing `grade.json` as a pass.

v0 stays red until `grade.json` from a Mac run has P1–P6 all `pass`.

## One-time setup

1. macOS 15 or newer. Xcode with the macOS 15 SDK. [XcodeGen](https://github.com/yonaskolb/XcodeGen) on `PATH`. Python 3.
2. Build the app, not a `swift run` binary:

   ```bash
   cd catcher
   xcodegen generate
   xcodebuild -project CatcherApp.xcodeproj -scheme CatcherApp \
     -destination 'platform=macOS' -derivedDataPath build build
   export CATCHER_APP="$PWD/build/Build/Products/Debug/Catcher.app"
   ```

   Sign with a stable development identity. Re-signing ad-hoc drops the TCC grant.
3. Launch `Catcher.app` once and grant **Screen & System Audio Recording** and **Microphone** to bundle id `com.catcher.app`. The granted identity is the app. A grant given to Terminal or Xcode does not count, and P2 will grade the wrong binary.
4. `export XAI_API_KEY=...` for any gate that uses Grok (`P1`, `P3`, `P6`). `CATCHER_ENGINE=grok` is the default. `CATCHER_ENGINE=stub` forces the deterministic engine.
5. Replace `catcher/harness/fixtures/known-60s.wav` with a clear ~60 s reading of `known-60s.ref.txt` before scoring P1. The file in git is a 16 kHz mono PCM16 carrier so the script has something to play. It is not that reading. WER against the reference will fail until you replace it.

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
  grade.json            written by harness/grade.py
  ../catcher.pid        pid of the app binary, next to the uuid directory
  ../revoke_wall_ms     P2 only, wall-clock milliseconds
```

`run.sh` resolves the newest child that contains `events.jsonl` and grades that directory. Default sessions outside the harness go to `~/Library/Application Support/Catcher/sessions/<uuid>/` with the same file names and no PCM unless `CATCHER_HARNESS=1`.

The harness starts `Catcher.app/Contents/MacOS/CatcherApp` so `CATCHER_SESSION_ROOT`, `CATCHER_HARNESS`, and `CATCHER_ENGINE` are visible. `open(1)` would drop them.

Library CI (`.github/workflows/catcher-ci.yml` on `macos-15`) runs `swift build` and `swift test` only. It does not produce `grade.json`.

## Gates

| Gate | What you do | Pass |
|---|---|---|
| **P1** | `run.sh p1 <dir>` plays the fixture, `kill -9`s the app, relaunches so crash recovery runs, then grades. | System-track WER ≤ 15 % against `known-60s.ref.txt`, no >2 s hole in system speech (uses `system.pcm` when present), and a recovered session. |
| **P2** | `CATCHER_ALLOW_TCC_RESET=1 run.sh p2 <dir>`. The script runs `tccutil reset ScreenCapture com.catcher.app` and waits for you to re-grant. | An `ann` with `kind: blocked` within 2 s of the revoke, and no `seg` after that timestamp. |
| **P3** | As root, `CATCHER_ALLOW_PF=1 run.sh p3 <dir>`. Blocks `api.x.ai:443` for 15 s, then clears the rule. | `ann` rows `degraded`, then `gap`, then `resumed`, then a `seg` at or after resume. |
| **P4** | Mute output, stay quiet, `run.sh p4 <dir>`. | `ann` `kind: noAudio` with `atMs` between 0 and 10000. |
| **P5** | `run.sh p5 <stub-dir> <grok-session-dir>`. Forces `CATCHER_ENGINE=stub` and replays the fixture. | JSONL row types and keys match the schema and the Grok session's shape. Transcript text is not compared. |
| **P6** | `run.sh p6 <dir>` while you talk over the fixture. | At least one `seg` on `microphone` and one on `system`, and a non-null `speaker` on a system `seg`. |

P2 and P3 refuse to touch TCC or the packet filter unless the matching `CATCHER_ALLOW_*` variable is `1`.

Score one session by hand:

```bash
python3 catcher/harness/grade.py --session <uuid-dir> --gate P1 \
  --ref catcher/harness/fixtures/known-60s.ref.txt --expect-recovery
python3 catcher/harness/wer.py --ref catcher/harness/fixtures/known-60s.ref.txt \
  --hyp <uuid-dir>/transcript.txt
```

`grade.py` exits 0 only when every requested gate is `pass`. Unrequested gates are `n/a`. A truncated last line of `events.jsonl` is ignored, matching crash recovery.

## What a pass is not

`swift test` passing, a stub session, or this document existing does not grade v0. QA copies `grade.json` out of the session directory from the Mac that ran the six gates. Until those six results are `pass`, v0 is red.
