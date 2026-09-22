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

**Dev TCC gotcha:** TCC bills the *responsible process*, and a binary exec'd from a shell inherits the shell's app as that process. `swift run`, a debug session under Xcode, or `Catcher.app/Contents/MacOS/CatcherApp &` from Terminal all read Terminal's or Xcode's microphone status, show Allow with their name on it, and never put Catcher in the Microphone pane. Start the app through LaunchServices: `open -n "$CATCHER_APP"` (the harness does this with `open --env … --args …`). Catcher checks `responsibility_get_pid_responsible_for_pid` at launch; if it is not itself, the banner says so and **Relaunch Catcher for microphone** respawns it through `NSWorkspace` with the same arguments and `CATCHER_*`/`XAI_API_KEY` environment.

Info.plist keys: `NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`. Bundle id: `com.catcher.app`. Entitlements: `Sources/CatcherApp/Catcher.entitlements` with `com.apple.security.device.audio-input`. The app is signed with the hardened runtime, and a hardened binary without that entitlement gets no TCC microphone case at all: no Allow dialog, no row in the Microphone pane, and whatever `AVCaptureDevice.authorizationStatus` returns is not a grant. `build-app.sh` fails the build if the entitlement is missing from the signed bundle.

**Microphone status in one line:** every microphone banner comes from a single readback, `MicrophoneAuthority`, logged to Console as `Catcher mic authority status=… recordPermission=… hardenedRuntime=… audioInputEntitlement=… responsiblePID=… responsible=… ownsTCCIdentity=… verdict=…`. The verdict order is signing, then attribution, then TCC status. If that line says `status=authorized` with the entitlement present and `ownsTCCIdentity=true`, the UI cannot say denied: the launch probe, the one-second recheck, and both buttons publish `verdict` and nothing else. The Microphone pane has no +; Catcher is listed there only once TCC holds a row for `com.catcher.app` (after a real Allow or Deny). Launch finishes the screen-capture prompt before asking for the microphone; `AVAudioApplication.requestRecordPermission` runs while status is `.notDetermined`, then `AVCaptureDevice.requestAccess`, both on the main actor. Per-call statuses are still logged as `Catcher mic authorizationStatus`. The microphone button is never a no-op: it re-reads the authority and then prompts (notDetermined), relaunches through LaunchServices (attribution), opens Privacy → Microphone (a stored denial for Catcher's own identity), or, when the microphone is fine, re-runs the capture probe so a stale banner clears. Re-grant opens Screen & System Audio for a screen-recording block. A Zoom call can hide Allow.

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
