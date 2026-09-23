# Transcription engine — 2026-09-22

**Decision (Nathan's pick): Grok Voice Transcribe 2.0 is the v0 engine and passed P1–P6 on the Mac** ([09-v0-shipped.md](09-v0-shipped.md), hardened GREEN `b14e31a`, CDHash `57250034b55e54e3ad6798983edf6e62c1553653`, board `/tmp/catcher-auto/b14e31a-20260923-055848/board.json`). P4 passing does not prove system audio was captured; that proof is P1. `MicrophoneGain` on the mic path (floor 0.05 unchanged) is why held speech clears median ≥ 0.1000 (P6 p50 0.2039, micGainMax 16). Chosen over the AssemblyAI-first recommendation on the strength of free diarization. It is not the locked default until the bake-off.

## Why Grok 2.0
- Released Sep 18, 2026 — four days old at pick time.
- $0.10/hr batch, $0.20/hr streaming; diarization, word timestamps, and key-term biasing included free (competitors charge diarization as an add-on).
- xAI claims: #1 of 32 streaming models on Artificial Analysis, 2x accuracy over v1.0, Atlassian evaluated it and moved all of Loom onto it.
- **Caveat:** every accuracy number above is vendor-reported, not independently reproduced. The 4-day age is the risk.

## The bake-off (before it locks)
A transcription harness (same pattern as the Jev spike) runs Grok 2.0 against **AssemblyAI Universal-3.5 Pro** on our own real audio and measures WER + diarization quality + cost. AssemblyAI is the challenger because it has the strongest independent evidence: 8.14% WER / 307ms P50 measured by Hamming.ai across 4M+ production calls, and the most honestly reported diarization (cpWER). Grok earns the default only when the verifier says it wins.

## The lab-dependency read
Grok is xAI — the same dependency class as Meta's Muse Voice Transcribe. The correction stands: **the engine is a commodity input, not the moat.** Granola already rents transcription from OpenAI/Anthropic. The moat is the context graph + the Jev judgment layer; no lab owns those. So the architecture keeps the engine behind a swappable interface (`TranscriptionEngine`: audio frames in, transcript events out) and lets the labs subsidize accuracy. Great supplier, bad landlord.

## The field (from the sentiment sweep, ranked for our use case)
1. **Grok Voice Transcribe 2.0** — cheapest credible accuracy, free diarization, 4-day caveat.
2. **AssemblyAI U3.5 Pro** — strongest independent evidence; the honest default.
3. **ElevenLabs Scribe v2 Realtime** — 3.6% WER, best live UX (transcript lands right at speech end), but no real-time diarization (batch only).
4. **Deepgram Nova-3** — the dev default (200k+ developers, $200 free credit), latency edge; accuracy trails; diarization is a paid add-on.
5. **Soniox** — budget pick, thin independent proof.
6. **Cartesia Ink-2** — watch.
- **Live-UX nuance:** first-partial WER is what the user *sees* while speaking — ElevenLabs 3.6% and AssemblyAI 4.1% hold up; Grok v1 was 18.3% (live transcript wrong until corrected). v2's number here is unproven.
- **Cheapest raw:** Groq Whisper ($0.00185/min large-v3) — no diarization, not a contender for v0.
- **Don't depend on:** Meta Muse Voice Transcribe (3.1% WER claim is lab marketing, tied to Meta's agent push).

## v0 wiring
Grok streaming: `wss://api.x.ai/v1/stt?model=grok-voice-transcribe-2.0&sample_rate=16000&encoding=pcm&interim_results=true` — raw PCM16 binary frames, `endpointing=800` (xAI's 10 ms default chops sentences). Full wire spec in [08-capture-layer.md](08-capture-layer.md).

Full research: `~/workspace/research_notes/transcription-model-research-20260922-0643/report.md`

Related: [08-capture-layer.md](08-capture-layer.md) · [06-strategic-reads.md](06-strategic-reads.md) · [03-jev.md](03-jev.md)
