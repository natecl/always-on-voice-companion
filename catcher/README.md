# Catcher (v0)

Mac app: system audio + microphone → transcription → verified transcript on disk.

```
ScreenCaptureKit (.audio + .microphone)
  → Pipeline (one TranscriptionEngine stream per track)
  → SessionStore JSONL
Verifier taps every hop and never sits in the data path.
```

Locked format: 16 kHz mono PCM16, `excludesCurrentProcessAudio`, 2×2 @ 1 fps video stub, whole-display capture, `endpointing=800`. `CATCHER_ENGINE=grok|stub` (default `grok`).

## Library tests

```bash
cd catcher
swift build
swift test
```

ScreenCaptureKit, the microphone permission prompt, and the SwiftUI app are macOS 15. On Linux those calls compile out; `swift test` still runs capture config, PCM, stub engine, Grok framing, verifier, JSONL, and pipeline tests. The GitHub workflow `.github/workflows/catcher-ci.yml` runs the same `swift build` / `swift test` on `macos-15`. That CI does **not** grade P1–P6.

## App (physical Mac)

```bash
cd catcher
./scripts/build-app.sh
export CATCHER_APP="$PWD/build/Build/Products/Debug/Catcher.app"
```

`CatcherApp.xcodeproj` is generated and gitignored. The script signs with a stable identity (`Catcher Development`, or Apple Development if `CATCHER_DEVELOPMENT_TEAM` is set). An ad-hoc signature is rejected: TCC would bind to the cdhash and the grant would not survive the next rebuild.

**Dev TCC gotcha:** the granted binary is the one you launch. A `swift run` from Terminal, or a debug session under Xcode, grants Terminal or Xcode — not Catcher. The harness launches `Catcher.app/Contents/MacOS/CatcherApp` and checks the bundle id is `com.catcher.app`.

Info.plist keys: `NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`. Bundle id: `com.catcher.app`.

`XAI_API_KEY` is required for `CATCHER_ENGINE=grok`. Audio is not sent until the socket receives `transcript.created`.

## Where sessions land

Default: `~/Library/Application Support/Catcher/sessions/<uuid>/`

| File | Contents |
|---|---|
| `events.jsonl` | `session`, `seg`, `ann`, `end`. Partials are not written. Finals and annotations are fsync'd. |
| `transcript.txt` | Time-interleaved `[me]` / `[them]` plus speaker label |
| `session.json` | Summary, including `recovered` after a crash |
| `system.pcm`, `microphone.pcm` | Raw PCM16 when `CATCHER_HARNESS=1` |
| `grade.json` | Written by `harness/grade.py` into the session directory |

Override the parent directory with `CATCHER_SESSION_ROOT`.

QA steps: [`docs/qa/v0-grading.md`](../docs/qa/v0-grading.md). v0 stays red until that run produces `grade.json` with P1–P6 `pass` on a physical Mac.
