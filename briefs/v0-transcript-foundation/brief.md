# v0 Brief — Audio In → Transcript Out
Status: APPROVED by Nathan 2026-09-22 — cleared for Cap to build
Date: 2026-09-22

## 1. One-liner
A Mac app that captures system audio + mic, streams it to a transcription engine, and writes a verified transcript to disk. Nothing else.

## 2. The slice
v0 proves one thing: **we can reliably turn real-world audio into a transcript, and we know loudly when we can't.** Every layer above this (notes, Jev judgment, interjection, the context graph) builds on a green v0. Nothing builds on a red one.

## 3. Architecture
```
ScreenCaptureKit          TranscriptionEngine          Verifier
(system + mic,           (interface — Grok 2.0        (health checks +
 two separate tracks)     is the first impl)           loud failures)
        │                        │                          │
        └──────────┬─────────────┘                          │
                   ▼                                        ▼
            audio pipeline → Grok streaming → transcript events → transcript on disk
```

**Components:**
1. **Capture** — ScreenCaptureKit. System audio (`.audio` track) + mic (`.microphone` track, macOS 15+), kept as two separate tracks end to end. Config: 16 kHz mono PCM, `excludesCurrentProcessAudio = true`, video stub 2×2 @ 1 fps. (Full spec: `research_notes/capture-layer-brief-20260922/report.md`)
2. **TranscriptionEngine (interface)** — the only swappable seam in v0. Contract: audio frames in (16 kHz mono PCM16), transcript events out (partial/final text, word timestamps, speaker labels, confidence). **Grok Voice Transcribe 2.0** is the first implementation behind it (`wss://api.x.ai/v1/stt`, `endpointing=800`). A second implementation (AssemblyAI) must be pluggable without touching capture or verifier — the bake-off harness will exercise this.
3. **Verifier** — runs alongside the pipeline, not after it. Owns every health check and owns every failure. Silence from the verifier means green; anything else is loud.
4. **Transcript store** — append-only transcript file per session: final text, word timestamps, speaker labels, confidence, plus verifier annotations (gaps, degraded windows). Segments on disk during capture; assembled on clean stop.

## 4. The verifier (the actual product of v0)
Granola's #1 user hate is silent capture failure — the app looks like it's recording and produces nothing. The verifier exists so that failure is impossible in v0. Checks:

- **Permission gate** — `startCapture()` attempted at launch. No TCC grant → loud onboarding block. The app never enters a fake "recording" state.
- **Audio-flowing check** — RMS energy per window on both tracks. Energy ≈ 0 for > 10 s while "recording" → loud "no audio detected" warning.
- **Transport heartbeat** — WebSocket handshake (`transcript.created`) must arrive before audio flows; timeout → fail loud, never buffer silently. Drops mid-session → reconnect with backoff, gap timestamped in the transcript.
- **Transcript sanity** — transcript length vs. session duration ratio; a 10-minute session with 30 seconds of text is flagged, not shipped.
- **Crash safety** — segments written continuously; a kill -9 mid-session still leaves recoverable segments on disk.

## 5. Pass / fail criteria (binary — defined before build)
v0 passes iff **all** of the following hold:

- **P1 — Known-audio round trip:** Play a 60 s reference audio file through system output while recording. Transcript produced, WER ≤ 15% vs. reference, no silent gaps > 2 s.
- **P2 — Permission denied:** Revoke Screen Recording permission, launch. App blocks loudly within 2 s with a re-grant path. No fake recording state.
- **P3 — Network kill:** Drop network mid-session. Session marked DEGRADED, the gap timestamped in the transcript, capture resumes on reconnect. No silent loss.
- **P4 — Silence:** Record 60 s of silence. Verifier fires "no audio detected" within 10 s.
- **P5 — Engine swap:** Replace the Grok implementation with a stub engine behind the same interface. Pipeline (capture → events → disk → verifier) works unchanged. Proves the seam is real.
- **P6 — Two tracks:** Play system audio while speaking into the mic. Both tracks preserved separately end to end; speaker labels present in the transcript.

Fail on any one = v0 is red, and nothing above it gets built.

## 6. Explicitly out of scope
- Notes, summaries, any LLM post-processing
- Jev judgment layer (validated by spike, parked for the layer above)
- Interjection / proactive voice
- Context graph, cross-session memory
- iOS / mobile, Windows
- Any UI beyond: record button, live transcript view, session list, verifier status

## 7. Research basis
- Transcription engine: `research_notes/transcription-model-research-20260922-0643/report.md` — Grok Voice Transcribe 2.0 picked ($0.10/hr batch, $0.20/hr streaming, diarization included); AssemblyAI is the bake-off challenger.
- Capture layer: `research_notes/capture-layer-brief-20260922/report.md` — ScreenCaptureKit config, permission UX, Grok wire format, gotchas.
- Sentiment: Grok 2.0 claims are 4-day-old vendor numbers — the bake-off harness validates them against AssemblyAI on real audio before Grok is locked as default.
- Landscape: `docs/knowledge/` (PR #2) — consumer wedge, Granola failure modes, always-on space.

## 8. Build order
1. Capture layer (hardest part — the OS plumbing)
2. Verifier (health checks + loud failures)
3. Grok wiring behind the TranscriptionEngine interface
4. Transcript store + minimal UI
5. Run P1–P6. Green → v0 ships. Red → fix the layer, not the layers above.

## 9. Open questions for Cap
- Diarization via Grok's `diarize` flag vs. multichannel 2-track vs. raw track separation — bake-off decides, interface must not care.
- Whole-display vs. per-app capture filter — whole-display for v0.
- Session file format details (JSONL vs. SQLite) — Cap's call, must support verifier annotations.
