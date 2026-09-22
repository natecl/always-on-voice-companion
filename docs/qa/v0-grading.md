# v0 grading (P1–P6)

Catcher v0 is system audio + mic → transcription → a verified transcript on disk. This page is how QA runs that proof on a **physical Mac**. A Linux agent VM and the `macos-15` library CI cannot grant Screen Recording, play audio, or kill the network. Do not treat `swift test` or a missing `grade.json` as a pass.

v0 stays red until `grade.json` from a Mac run has P1–P6 all `pass`.

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
  ../live_session       absolute path of the first recording (harness only)
  ../revoke_session     P2: that path, copied before tccutil reset
  ../revoke_wall_ms     P2 only, wall-clock milliseconds
```

`run.sh` resolves the newest child that contains `events.jsonl` and grades that directory, except P2. P2 grades `revoke_session` (the recording that was live at the reset), not a later session whose only `blocked` ann is at `atMs=0` from a failed `startCapture`. Default sessions outside the harness go to `~/Library/Application Support/Catcher/sessions/<uuid>/` with the same file names and no PCM unless `CATCHER_HARNESS=1`.

The harness starts `Catcher.app` through LaunchServices (bundle id `com.catcher.app`, not an ad-hoc side binary, and verified to carry the `com.apple.security.device.audio-input` entitlement). Stock `open` has no `--env`, so the harness compiles `launch_services.swift` and calls `NSWorkspace.openApplication`, passing the shell environment through (`CATCHER_SESSION_ROOT`, `CATCHER_HARNESS`, `CATCHER_ENGINE`, `CATCHER_AUTO_RECORD`, `XAI_API_KEY`) and the same switches as `--session-root`, `--harness`, `--engine`, and `--auto-record`. It does not exec the binary from the shell: that would bill microphone access to Terminal. The app writes `catcher.pid` itself once it is up, and `lib.sh` waits for that file.

After a P1 run, `system.pcm` in the session directory is the capture proof. It is absent when no `PCMFrame` was emitted. A file of the right length that is all zeros is still a failed capture: `afplay` of the fixture must show a non-zero peak and RMS, and system `seg` rows must have text. A `noAudio` annotation at 10s also fires when zero frames arrived, so P4 passing does not show that system audio was captured. The microphone track can look healthy at the same time; that does not prove the system track.

Library CI (`.github/workflows/catcher-ci.yml` on `macos-15`) runs `swift build` and `swift test` only. It does not produce `grade.json`.

## Gates

| Gate | What you do | Pass |
|---|---|---|
| **P1** | `run.sh p1 <dir>` plays the fixture, `kill -9`s the app, relaunches so crash recovery runs, then grades. | System-track WER ≤ 15 % against `known-60s.ref.txt`, no >2 s hole in system speech (uses `system.pcm` when present), and a recovered session. |
| **P2** | `CATCHER_ALLOW_TCC_RESET=1 run.sh p2 <dir>`. The script runs `tccutil reset ScreenCapture com.catcher.app` and waits for you to re-grant. The score is the session that was recording at the reset. | An `ann` with `kind: blocked` on that live session within 2 s of the revoke, and no `seg` after that timestamp. |
| **P3** | As root, `CATCHER_ALLOW_PF=1 run.sh p3 <dir>`. Blocks `api.x.ai:443` for 15 s, then clears the rule. After the rule clears, wait for the reconnect backoff (1, 2, 4, 8 s) before pressing enter. | `ann` rows `degraded`, then `gap`, then `resumed`, then a `seg` at or after resume. |
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
