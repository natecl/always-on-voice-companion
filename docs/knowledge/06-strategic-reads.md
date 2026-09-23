# Strategic reads — 2026-09-22

Synthesized judgments from the deep-research pass and the founder's decisions tonight. This is the living strategy page; update it when new research changes the read.

## The sequence (locked)

1. **Spike validates Jev** — DONE, PASS (2026-09-22; see [03-jev.md](03-jev.md)).
2. **Build the proven base** — v0 transcript foundation GREEN (`95837a8`); notes and judgment brief next. (Consumer wedge: [01-consumer-wedge.md](01-consumer-wedge.md).)
3. **Trial the new** — the always-on buddy with Jev-powered interjection. Expect it wrong first (Pincus: "the new gets the trial").

Nathan approves the brief (pass/fail defined first) before Cap builds anything.

## The Wispr Flow read: sharpens, doesn't upend

The track-5 research changed the bet's edges, not its shape:

1. **The proven slice now faces two incumbents, not one.** Granola ($1.5B) + Wispr Notetaker ($2B, free through Oct 31, courts Granola defectors). The bar is no longer "clone Granola" — it's **Granola's UX + Wispr's accuracy ambition** (Canto, named diarization). A me-too notetaker loses; the proven slice has to hit both.
2. **Privacy is the front-door wedge.** Granola has a wiretap class action ($5,000/violation); Wispr has a screenshot/audio incident with a banned whistleblower + mandatory cloud + opt-out training. Both are structurally weak on trust. Ship **training-off-by-default, local-first capture, verifiable privacy** as the product's front door, not a settings page.
3. **The race is the buddy, not the notetaker.** Wispr has the capture layer, the dictation heritage, and distribution — but its notetaker is still *reactive*. If they add judgment first, they win. So the proven slice's job is just to buy the right to trial the new — and the new needs to be in trials fast.

**Thesis-filter check:** a pure notetaker now fails "not ownable by a well-funded incumbent" — Wispr at $2B is effectively an incumbent in voice. The company is the buddy + judgment layer; the notetaker is the wedge.

## The 5 open gaps (from the research takeaways)

1. **Fix capture reliability.** Silent failure is the most-hated property in the category: capture health checks, loud failure alerts, user-controlled encrypted audio retention, file import. > "A generic summary can be edited. A blank session cannot."
   - Status: capture health checks and loud failures shipped in v0. Encrypted retention and file import are not built.
2. **Solve the proactivity trigger with Jev.** Friend proved unprompted AI reads as creepy; full-duplex infra just shipped with no judgment layer. Calibrated Noul/Choice/Score gates at $42/B tokens, 70–500ms — the first economically viable "should I speak now?" machinery. Build the interruptibility score.
3. **Make privacy verifiable, not promised.** Training-off-by-default, local-first, auto-expiring transcripts — ship what Pedregal says he's *researching* before he does.
4. **No hardware — colonize the devices people already wear.** Phone mics + earbuds; the meeting flow Granola proved. Hardware is where startups in this space go to die.
5. **Copy Granola's mechanics + notepad framing verbatim; differentiate on agency.** Reliable capture with audio fallback; the Jev-powered buddy that listens across the day and acts only on calibrated judgment; Garry Tan's gbrain pattern — user-owned memory graph, transcripts as *claims with provenance*.

## PBN framing (Pincus, from the live teardown)

- **Proven** = Granola's mechanics, legally copied. Don't test it, don't question it — it's what users come back for.
- **Better** = free / faster / less friction. **Zero latency is better, not new.**
- **New** = always-listening. Gets the trial, not the return. Expect it wrong at first — "how could we have a trial where the new thing is the most wrong and nobody cares?" Back-of-the-box vs. what you come back for.
- **Death of ego:** judge the new by testing variants, not by defending it.
- **Distribution:** there is no proven consumer distribution path — the viral hook has to live inside the product. (Prosumer / 20M-developer wedge under consideration.)

## The v0 slice (2026-09-22)

The proven base is being built narrow-slice, not as a Granola clone:

- **v0 = audio in → transcript out, plus a verifier.** Capture (ScreenCaptureKit) → Grok 2.0 behind a swappable `TranscriptionEngine` interface → verified transcript on disk. Nothing above it (notes, Jev, interjection, graph) builds until v0 is green.
- **The verifier is the product of v0** — capture health checks, loud failures, binary pass/fail. It exists because silent capture failure is the category's most-hated property.
- **Build order:** capture layer first (the hard part), verifier second, Grok wiring third.
- **Engine is a commodity input, not the moat** — Grok is xAI, same dependency class as Meta. The moat is the context graph + Jev judgment; the interface keeps the engine swappable so no lab is a landlord.
- v0 brief drafted at `~/workspace/briefs/v0-transcript-foundation/brief.md` (local, not in repo) — six binary gates (P1–P6). Approved 2026-09-22, built, and graded green. See [09-v0-shipped.md](09-v0-shipped.md).

## Related

- [00-product-one-liner.md](00-product-one-liner.md) · [01-consumer-wedge.md](01-consumer-wedge.md) · [02-granola.md](02-granola.md) · [03-jev.md](03-jev.md) · [04-always-on-space.md](04-always-on-space.md) · [05-wispr-flow-notetaker.md](05-wispr-flow-notetaker.md)
- `../proven-better-new.md` · `pincus-tan-takeaways.md` · `granola-baseline.md` · `jev.md`
