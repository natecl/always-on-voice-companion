# Proven / Better / New

The product framework from Marc Pincus's *Life at the Speed of Play*, as applied to the
always-on voice companion. Source: the Pincus + Gary Tan Lenny's Podcast conversation
(see `knowledge/pincus-tan-takeaways.md`).

## The framework

Start from an instinct that something's missing. Isolate it, and make sure you're testing
**just that instinct** — not the things you don't want to test.

- **Proven.** Find the most successful product in the space, deconstruct it, and legally copy
  everything you're not innovating on. Don't question it, don't try to improve it — "we don't
  have time, that's where we're in the wheel." Proven is what users come back for.
- **Better.** Something 10 out of 10 existing users would say is better: free, half price,
  faster, less friction. Better gives you direction.
- **New.** Exactly one innovation zone — the instinct. Start with the proposition that it's
  **probably wrong**, don't get attached, and test lots of variants around it. New is the
  spikes that go out; "be prepared for none of them to catch." New gets the trial
  (the back of the box — what got you to buy the cereal), but it's probably not what you
  come back for.

Supporting rules from the same conversation:

- **Death of the ego.** Stay passionate about the vision, dispassionate about any particular
  product variant. Give yourself permission to pivot a lot.
- **Heat / fish are running.** When you have true signal you know it — you don't need metrics,
  every feedback loop is a yes, nobody needs to be told to work harder. "Great product makers
  are collecting winnings, not making bets" — you know it's a hit long before launch.
- **Distribution isn't an afterthought.** No proven consumer distribution path exists right now;
  figure it out by hook or by crook — ideally a viral hook inside the product.
- **The $1,000/month test.** If the magical version costs $1,000/month, it's enterprise, not
  consumer. Consumer arrives when intelligence is squanderable (Jevons paradox).

## Our PBN

**Proven — straight copy Granola.**
Live transcript, auto-generated notes, shareable output. The most successful AI notetaker;
copy the mechanics at pixel level. Zero innovation budget, zero testing budget here.

**Better — kill all friction.**
No bot to invite, no setup dance, just on. Near-zero latency responses (Pincus and Tan put
zero-latency in *better*, not new — everyone says yes to it). Consumer-cheap via Jev
judgment instead of frontier-model spend. Loud capture — never a silent blank session —
shipped with the v0 transcript foundation.

**New — the always-listening voice buddy.**
The AI as a smart other person at the table: you turn to it mid-conversation and ask its
take, sometimes it interjects on its own, and it holds full context of your life (emails,
texts, calendar, past conversations — the Gary Tan therapy-session hack, productized).
This gets the trial. Expect it to be wrong first; test variants of the interjection policy,
the listening surface, and the context depth independently.

## What we're testing, in order

1. Can Jev judge utterances (commitment / deadline / decision / interrupt-worthy) with
   useful calibration? (Afternoon spike on real transcripts — before any build.)
2a. Can we capture reliably and loudly? DONE — v0 foundation green
   ([09-v0-shipped.md](knowledge/09-v0-shipped.md)).
2b. Is the 2-second judgment brief the heat? (v0 catcher, next.)
3. Does live mid-conversation participation earn the turn-to-it behavior? (v1.)
4. Does proactive interjection delight or annoy? (v2 — the buddy.)
