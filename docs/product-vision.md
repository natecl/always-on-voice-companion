# Product Vision: Always-On Voice Companion

**Status:** vision spec — the north star. The v0 build brief (with pass/fail) is a separate,
smaller document. Nothing here is a build order until the v0 brief is approved.

## One-liner

Granola, but it listens. An always-on voice buddy with full context of your life:
you walk around talking to it, you turn to it mid-conversation, sometimes it jumps in on its own.

## The problem

Everyone who wants this today hacks it together: voice memo → transcript → paste into a
bot (Gary Tan's exact workflow is Granola transcript → OpenClaw, asking "is there anything
from the last week I should have brought up?"). The friction proves the latent demand.
Granola nailed the proven mechanics but stopped — nobody built the always-on layer,
because on frontier-model economics it would cost ~$1,000/month. That's an enterprise
product, not a consumer one.

## The product

A companion that hears what you hear:

- **Ambient listening.** It's just on. No bot to invite, no meeting setup, no record button.
- **Turn to it.** Any moment, mid-conversation, you ask its take — and it answers with full
  context of your life: emails, texts, calendar, past conversations.
- **It jumps in.** Sometimes it interjects on its own — gated by judgment confidence, so it's
  a companion, not Clippy.
- **The 2-second brief.** After any conversation: every commitment, deadline, and decision,
  judged — not summarized.

## Proven / Better / New (ours)

- **Proven:** copy Granola at pixel level — live transcript, auto notes, shareable. No innovation budget.
- **Better:** kill all friction (just on), near-zero latency responses, consumer-cheap via Jev.
- **New:** the always-listening buddy with full life context. Gets the trial; expect it to be wrong first.

## How it works

1. **Always-on audio → streaming transcription** (Whisper-class, on-device where possible).
2. **Jev judgment stream.** Every utterance is judged in real time: commitment? deadline?
   decision? question for me? interrupt-worthy? Calibrated confidence scores gate everything
   downstream — including whether the companion speaks.
3. **Life-context store.** Emails, messages, calendar, past transcripts — indexed for retrieval.
   Jev triages which context is relevant before the companion model answers.
4. **Companion brain (LLM).** Full-context answers and interjection, invoked only when the
   judgment layer says it's worth it.
5. **Voice out.** Low-latency voice I/O (near-zero latency is the bar — Thinking Machines'
   breakthrough goes in "better").

## Why Jev (the unlock)

Pincus: "we've got to get to that Jevons paradox point where you can squander it." Jev is
literally named after the Jevons paradox. Judging every utterance with a frontier model is
what makes always-on cost $1,000/month. Jev judges at $0.042/M input tokens with free output
in ~200ms — so per-utterance judgment becomes squanderable, and the product becomes
consumer-priced. Without Jev, this vision is not buildable at consumer economics. That is
the entire bet.

## Phases

- **v0 — the catcher (embarrassingly small).** Per-call record/upload → transcript → Jev
  judges every utterance → 2-second judgment brief. Tests: is the judgment brief the heat?
- **v1 — the participant.** Live in-conversation: turn to it mid-call, ask with full context.
- **v2 — the buddy.** True always-on: ambient listening, proactive interjection gated by
  judgment confidence.

Each phase only starts if the previous one shows heat ("the fish are running").

## Moats

- **Per-user life-context flywheel.** The longer it listens, the more context it holds, the
  better its judgment gets. Data moat per user.
- **Jev judgment tuning per user.** Calibrated interruption policy learned from your
  corrections — uncopyable without your data.
- **Voice-first craft.** Wispr Flow proved craft wins in voice. The bar is daily-habit quality.
- **Neutral position.** Not a lab, not a harness vendor — the companion layer above all of them.

## Open questions

- Interjection policy: exactly when does it jump in vs. stay quiet? (Jev confidence thresholds, user-tunable.)
- Privacy model for always-on: on-device vs. cloud, per-conversation consent, what gets stored.
- Platform order: v0 desktop-first vs. phone-first. (Vision is voice-everywhere: phone, desktop, whatever.)
- Distribution: prosumer/whales first (founder is whale #1), then the viral hook. Distribution
  can't be an afterthought — Pincus.

## What it's not

- Not a meeting notetaker (that's proven — we copy it, we don't innovate on it).
- Not a social or entertainment product. Utility is a hard bar.
- Not an agent router or a lab competitor. We surf model progress; we don't race the labs.
