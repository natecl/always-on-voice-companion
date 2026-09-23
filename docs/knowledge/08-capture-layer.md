# Capture layer — 2026-09-22, updated at `95837a8`, shipped v0

**Verdict:** solved engineering, not open research. ScreenCaptureKit delivers 48 kHz stereo float; the app downmixes and resamples that to 16 kHz mono PCM16 (`SampleBufferPCM`, `PCMFrame`). The provider is the easy part; the OS audio plumbing is the actual build.

## The v0 pipeline
```
ScreenCaptureKit (system audio + mic, two tracks; 48 kHz stereo float)
  → CMSampleBuffer float32, often non-interleaved, at the configured rate
  → convert to PCM16 @ 16 kHz mono (SampleBufferPCM, PCMFrame)
  → one engine stream per track
  → WebSocket binary frames (~100 ms chunks)
  → Grok Voice Transcribe 2.0 streaming
  → transcript.partial / transcript.done events
  → verified transcript on disk

Verifier taps frames, engine state, events, and the store, and writes
annotations into the same JSONL. It drives UI status and does not sit
in the data path.
```

## ScreenCaptureKit config
```swift
config.capturesAudio = true
config.captureMicrophone = true           // macOS 15+, separate .microphone track
config.excludesCurrentProcessAudio = true  // mandatory — no feedback loop
config.sampleRate = 48000                  // SCK default. 16 kHz mono on the system track is silence
config.channelCount = 2                    // stereo float; downmix after the copy. Do not ask SCK for mono
config.width = 2; config.height = 2        // collapse the video stub
config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
```
- **Two tracks, always:** `.audio` (system — "them") + `.microphone` (mic — "me"). Kept separate end to end; "me vs. them" attribution comes free. Never mix in the pipeline.
- **System mix is the whole display, not `excludingWindows`.** `SCContentFilter(display:excludingWindows:)` only carries audio from apps that have windows on that display, so `afplay` (no window) is silence while the mic still hears the room. Use `excludingApplications: []` on the main awake display. `displays.first` can be a closed-lid built-in whose `.audio` mix is zeros.
- **Do not average opposite-polarity system channels.** SCK system float is often non-interleaved stereo where channel 1 is the inverse of channel 0. The mic buffer is one channel. An average of the system pair is digital silence (`system.pcm` the right length, peak 0). Keep the loud channel when the average cancels. Pipeline frames are still 16 kHz mono PCM16.
- **Audio-only is undocumented but works** — validated across macOS 14/15/26 in shipping apps. The video pipeline still runs internally; the 2×2 @ 1 fps stub keeps it cheap. Console noise ("stream output NOT found. Dropping frame") is cosmetic.
- macOS 13+ for audio capture; 15+ for in-stream mic.

## Two tracks, shipped

`.audio` is system ("them") and `.microphone` is the mic ("me"). `transcript.txt` prefixes each line `[them]` or `[me]`. Each `seg` row has a `track` field, `system` or `microphone`.

## Reconnect path (shipped)

1. A socket stall marks the session `degraded`.
2. The next socket opens without waiting for a parked `URLSession` close. Backoff is 1, 2, 4, 8, 16 s, then capped at 30 s.
3. The new socket's origin carries `gap{fromMs,toMs}`.
4. `resumed` is sent only after a post-resume final is queued, or the catch-up budget ends.
5. Word times are rebased by `originMs`.

P3 on the Mac run at `95837a8` grades this path. Pass conditions are the gate table in [v0 grading](../qa/v0-grading.md#gates).

Two bugs blocked P3 until they were fixed:

- A pf-dropped `URLSessionWebSocketTask` never finishes `cancel()`, so reconnect must not wait for it.
- Receive must be armed before replaying buffered audio, or the post-resume final is lost.

## noAudio detection (shipped)

`noAudio` uses AC RMS with DC removed. The floor is `rmsEpsilon = 0.05` (about −26 dBFS), the speech hold is 300 ms, and the limit is 10 s. A resting mic (DC offset, room tone) counts as silence. The annotation fires even when zero frames arrived.

A resting mic's DC offset and room tone kept the plain-RMS silence clock resetting, so `noAudio` never landed inside 10 s. AC RMS is what makes the 10 s clock run on that rest energy.

P4 passing does not prove system audio was captured. P1's `system.pcm` peak/RMS and system `seg` text do. Pass conditions: [v0 grading](../qa/v0-grading.md#gates).

## Permission UX
- **Screen capture is purely TCC-gated — no entitlement, no Apple approval.** `NSScreenCaptureUsageDescription` in Info.plist (missing = app terminated).
- **Microphone is not, once the hardened runtime is on:** a hardened binary needs `com.apple.security.device.audio-input` or TCC opens no microphone case — no Allow, no row in the Microphone pane, and `AVCaptureDevice.authorizationStatus` is not a grant. Catcher.app is hardened; the entitlement lives in `Catcher.entitlements`.
- The LaunchServices grant procedure is setup step 3 in [v0 grading](../qa/v0-grading.md#one-time-setup).
- Verifier hook: attempt `startCapture()` at launch — no grant → loud onboarding block, never a fake "recording" state.

## Grok streaming wire format
- `wss://api.x.ai/v1/stt?model=grok-voice-transcribe-2.0&sample_rate=16000&encoding=pcm&interim_results=true&language=en`
- Raw binary PCM16 frames (~100 ms / 3,200 bytes), no base64. Wait for `transcript.created` before sending; close with `{"type":"audio.done"}`.
- **Endpointing gotcha:** xAI defaults to 10 ms — chops sentences at micro-pauses. Set `endpointing=800`.
- Interim results ~every 500 ms. Opus accepted at ~4 KB/s vs 48 KB/s PCM (bandwidth option). Multichannel up to 8 ch (bake-off may use 2-ch system+mic as a diarization alternative).
- Limits: 100 concurrent streaming sessions/team — fine for v0.

## Gotchas for Cap
1. Extract SCK audio with `CMSampleBufferCopyPCMDataIntoAudioBufferList` into a list sized from the buffer's own format (float32, one `AudioBuffer` per channel when non-interleaved), then convert to 16 kHz mono PCM16. `-12737` is `kCMSampleBufferError_ArrayTooSmall`: the list had one buffer and the system track is non-interleaved multi-channel. A PCM16-sized destination fails the copy too; discarding that error yields zero frames and no `system.pcm`. A copy that succeeds can still be all zeros if the channels are then averaged. If that copy is silent, read the contiguous planar float block (channel `c` at sample `c * frameCount`) before accepting silence.
2. `updateConfiguration` **replaces**, never merges — always pass the complete config or sample rate/channels/audio flags silently reset.
3. Write segments continuously, assemble on clean stop (crash-safe recording).
4. `Data.removeFirst` / `insert(at: 0)` on a slice traps once reconnect runs; rebuild buffers.
5. Keep the Grok socket's unfair lock out of async contexts (`f3a68b4`).

## Failure modes → verifier hooks
Rows below name the failure. Pass conditions live only in the gate table in [v0 grading](../qa/v0-grading.md#gates).

| Failure | Detection | Behavior | Graded by |
|---|---|---|---|
| No TCC permission | `startCapture()` throws | Loud onboarding gate | none |
| Stream alive, silent buffers | RMS energy ≈ 0 > 10 s | Loud "no audio detected" | P4 |
| WebSocket drop | connection loss | Reconnect + backoff; gap timestamped | P3 |
| No `transcript.created` | handshake timeout | Fail loud — never buffer silently | none |
| Permission revoked mid-session | stream delegate error | Stop, surface, re-gate | P2 |

This is the anti-Granola layer: silent capture failure is the category's most-hated property, and the verifier exists so it's impossible in v0.

Full brief (local, not in repo): `~/workspace/research_notes/capture-layer-brief-20260922/report.md`

Related: [07-transcription.md](07-transcription.md) · [09-v0-shipped.md](09-v0-shipped.md) · [06-strategic-reads.md](06-strategic-reads.md) · [02-granola.md](02-granola.md)
