# Capture layer — 2026-09-22

**Verdict:** solved engineering, not open research. ScreenCaptureKit delivers 16 kHz mono PCM directly — exactly what Grok's streaming endpoint consumes. The provider is the easy part; the OS audio plumbing is the actual build.

## The v0 pipeline
```
ScreenCaptureKit (system audio + mic, two tracks)
  → CMSampleBuffer PCM16 @ 16 kHz mono
  → WebSocket binary frames (~100 ms chunks)
  → Grok Voice Transcribe 2.0 streaming
  → transcript.partial / transcript.done events
  → verified transcript on disk
```

## ScreenCaptureKit config
```swift
config.capturesAudio = true
config.captureMicrophone = true           // macOS 15+, separate .microphone track
config.excludesCurrentProcessAudio = true  // mandatory — no feedback loop
config.sampleRate = 16000                  // SCK resamples; no manual conversion
config.channelCount = 1
config.width = 2; config.height = 2        // collapse the video stub
config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
```
- **Two tracks, always:** `.audio` (system — "them") + `.microphone` (mic — "me"). Kept separate end to end; "me vs. them" attribution comes free. Never mix in the pipeline.
- **Audio-only is undocumented but works** — validated across macOS 14/15/26 in shipping apps. The video pipeline still runs internally; the 2×2 @ 1 fps stub keeps it cheap. Console noise ("stream output NOT found. Dropping frame") is cosmetic.
- macOS 13+ for audio capture; 15+ for in-stream mic.

## Permission UX
- **Purely TCC-gated — no entitlement, no Apple approval.** `NSScreenCaptureUsageDescription` in Info.plist (missing = app terminated).
- User grants once: System Settings → Privacy & Security → Screen & System Audio Recording.
- Dev gotcha: during development the granted binary is the terminal/IDE, not the app.
- Verifier hook: attempt `startCapture()` at launch — no grant → loud onboarding block, never a fake "recording" state.

## Grok streaming wire format
- `wss://api.x.ai/v1/stt?model=grok-voice-transcribe-2.0&sample_rate=16000&encoding=pcm&interim_results=true&language=en`
- Raw binary PCM16 frames (~100 ms / 3,200 bytes), no base64. Wait for `transcript.created` before sending; close with `{"type":"audio.done"}`.
- **Endpointing gotcha:** xAI defaults to 10 ms — chops sentences at micro-pauses. Set `endpointing=800`.
- Interim results ~every 500 ms. Opus accepted at ~4 KB/s vs 48 KB/s PCM (bandwidth option). Multichannel up to 8 ch (bake-off may use 2-ch system+mic as a diarization alternative).
- Limits: 100 concurrent streaming sessions/team — fine for v0.

## Gotchas for Cap
1. Extract SCK audio with `CMSampleBufferCopyPCMDataIntoAudioBufferList` — the `GetAudioBufferListWithRetainedBlockBuffer` variant fails with `-12737` on SCK buffers.
2. `updateConfiguration` **replaces**, never merges — always pass the complete config or sample rate/channels/audio flags silently reset.
3. Write segments continuously, assemble on clean stop (crash-safe recording).

## Failure modes → verifier hooks
| Failure | Detection | Behavior |
|---|---|---|
| No TCC permission | `startCapture()` throws | Loud onboarding gate |
| Stream alive, silent buffers | RMS energy ≈ 0 > 10 s | Loud "no audio detected" |
| WebSocket drop | connection loss | Reconnect + backoff; gap timestamped |
| No `transcript.created` | handshake timeout | Fail loud — never buffer silently |
| Permission revoked mid-session | stream delegate error | Stop, surface, re-gate |

This is the anti-Granola layer: silent capture failure is the category's most-hated property, and the verifier exists so it's impossible in v0.

Full brief: `~/workspace/research_notes/capture-layer-brief-20260922/report.md`

Related: [07-transcription.md](07-transcription.md) · [06-strategic-reads.md](06-strategic-reads.md) · [02-granola.md](02-granola.md)
