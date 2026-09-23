# The product, in one sentence

> **Granola, but it listens — an always-on voice buddy with full context of your life that sometimes jumps into the conversation.**

Pincus's own back-of-the-box line, plus the interjection.

## Unpacking it (PBN)

- **Proven** — Granola's mechanics, copied straight: live transcript, auto notes, shareable output. Zero innovation budget here. See `granola-baseline.md` and [02-granola.md](02-granola.md).
- **Better** — kill all friction: no bot to invite, just on; near-zero latency; judgment at consumer price instead of "$1,000 a month" enterprise price.
- **New** — the always-listening voice buddy itself: "the smart other person at the table… maybe sometimes it'll interject" (Pincus). You turn to it mid-conversation; it has total context of your life — emails, texts, past calls, voice memos — and it acts only when calibrated judgment clears the bar.

## The 10x lever

**Jev** (TypeSafe AI) — a decision model, not a text generator. Per-utterance judgment (commitment? deadline? should I speak now?) at $0.042/M input tokens, 70–500ms latency — the Jevons-paradox unlock that makes always-on judgment squanderable at consumer price. The interjection policy is gated by Jev's calibrated confidence; the spike validated it on a real 521-utterance transcript (PASS: 100% recall on commitments/deadlines). See [03-jev.md](03-jev.md).

The v0 transcript foundation has hardened GREEN evidence at `b14e31a` ([09-v0-shipped.md](09-v0-shipped.md)): CDHash `57250034b55e54e3ad6798983edf6e62c1553653`, board `/tmp/catcher-auto/b14e31a-20260923-055848/board.json`, preflight and P1–P6 pass under the hardened verifier (soft-pass killed). `MicrophoneGain` on the mic path (floor 0.05 unchanged); P6 p50 0.2039, micGainMax 16. Jev is not yet in the pipeline; the spike result stands on its own.

## What it is NOT

- Not a meeting notetaker (Granola and Wispr Flow already won that; it's our wedge, not our company).
- Not a companion pendant (hardware is where always-on startups go to die — see [04-always-on-space.md](04-always-on-space.md)). It lives on the phone mic and earbuds people already wear.

Related: [01-consumer-wedge.md](01-consumer-wedge.md) · [06-strategic-reads.md](06-strategic-reads.md) · `../proven-better-new.md`
