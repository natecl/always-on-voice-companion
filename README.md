# Always-On Voice Companion (working title)

The product Marc Pincus and Gary Tan sketched on Lenny's Podcast: Granola, but always listening.
A voice buddy with full context of your life — you walk around talking to it, you turn to it
mid-conversation, sometimes it jumps in on its own.

> "Almost certainly a 10 or 100 billion dollar company that no one's built yet." — Gary Tan

## Superpower: Jev

Continuous judgment of every utterance is only affordable because of TypeSafe AI's **Jev** —
a decision model (not a text generator) returning Choice/Score/Noul outputs with calibrated
confidence at $0.042/M input tokens, output free, 70–500ms latency. Pincus and Tan's whole
point: always-on AI "will just cost $1,000 a month" on frontier models. Jev is the
Jevons-paradox unlock that makes always-on judgment squanderable at consumer price.

## Proven / Better / New

- **Proven** — straight copy Granola: live transcript, auto notes you can share. Zero innovation budget here.
- **Better** — kill all friction: no bot to invite, just on. Faster (near-zero latency) and cheaper.
- **New** — always-listening voice buddy with full life context. Gets the trial; expect it to be wrong first.

v0 transcript foundation: green on Mac at `95837a8`.

## Repo map

- `catcher/` — v0 Mac catcher (system audio + mic → verified transcript). QA: `docs/qa/v0-grading.md`
- `docs/qa/v0-diagnostics.md` — stage checkpoints and preflight; these files do not grade P1–P6
- `docs/knowledge/08-capture-layer.md` — shipped capture, reconnect, and noAudio
- `docs/knowledge/09-v0-shipped.md` — what the v0 transcript foundation is, and the Mac evidence
- `docs/plans/` — plans, including the v0 knowledge refresh
- `docs/product-vision.md` — overarching product vision spec
- `docs/proven-better-new.md` — the PBN framework, plus our PBN applied
- `docs/knowledge/jev.md` — Jev model facts, pricing, access
- `docs/knowledge/pincus-tan-takeaways.md` — distilled takeaways from the Pincus/Tan conversation
- `docs/knowledge/granola-baseline.md` — the proven Granola mechanics we're copying
