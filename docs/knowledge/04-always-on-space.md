# The always-on notetaker / voice-agent space

Deep research pass 2026-09-22. The graveyard and the gaps — why nobody has become the always-on companion, and what's still unsolved.

## Product map

| Product | Maker / status | What it does | Price | Outcome |
|---|---|---|---|---|
| **Limitless Pendant** | Limitless (Rewind) | Always-listening pendant; transcribes into searchable knowledge | $99 device; $29/mo unlimited | **Acquired by Meta Dec 2025**; sales halted, Rewind kill-switched Dec 19, 2025; team → Reality Labs |
| **Bee** | Bee | $50 screen-free wristband; transcribes everything, daily summaries, proactive Gmail/calendar actions; **no audio stored** | $49.99 + $19/mo, or free Apple Watch app | **Acquired by Amazon Jul 2025**; absorbed into "ambient AI"; reviews poor — Verge: "all I got was fanfiction" |
| **Omi** | Based Hardware (Nik Shevchenko, Thiel fellow) | $89 always-listening orb (necklace/temple); no wake word; single-electrode "brain interface"; open-source | $89 | Shipped Q2 2025; niche/dev community; fragile demo |
| **Friend** | Avi Schiffmann | Always-listening **companion** pendant; **proactively texts unprompted** ("free will") | $99 → $129 → **$249** (2.0, Jul 2026) | ~3,000 units, ~$348K revenue vs ~$1M marketing; subway ads defaced ("surveillance tool"); Wired: "incredibly antisocial" |
| **Plaud** (Note/NotePin S/Note Pro) | Plaud | **Press-to-record** recorder (NOT always-on); dual-mode phone-call + in-person; Mac notetaker Jan 2026 vs Granola | $159–$189; minute-metered (300 min/mo free; Pro $99.99/yr; Unlimited $239.99/yr) | **>1.5M devices sold** — the only traction story |
| **Humane AI Pin** | Humane | Screenless AI pin, laser projector | $700 + $24/mo | **Dead Feb 28, 2025**; assets → HP for $116M (raised $230M+) |
| **Rabbit R1** | Rabbit | "Phone replacement" AI gadget | $199 | 100K sold; ~5K DAU months later (95% dropout) |

## Why none became the companion

1. **The phone ate them.** Apple Intelligence / Gemini at the OS layer made dedicated AI gadgets redundant; reviewers went back to phones that "could do all the features they liked."
2. **No killer behavior, weak AI.** Humane's assistant was "so bad that it killed any potential" (Engadget); Rabbit kept 5% of buyers as daily users.
3. **Creep, not convenience.** Friend is the cautionary tale: ~$1M subway blitz defaced within two weeks ("surveillance tool" scrawled on the founder's face), Heineken parody, Wired's "wearing a wire" moment — always-listening hardware reads as surveillance jewelry to bystanders.
4. **Economics.** Friend: ~$348K revenue against ~3× that in marketing. Small players couldn't outlast Meta/Amazon/OpenAI (Limitless founders said exactly this).
5. **Quiet absorption.** Bee → Amazon, Limitless → Meta — "the fourth kind of death… where nobody even bothers with a funeral."
6. **The exception:** Plaud's 1.5M devices came from **explicit press-to-record** — not always-on listening. Users buy a recorder; they recoil at a listener.

**The takeaway: don't build hardware.** Colonize phone mics + earbuds and the meeting flow Granola proved. Hardware is where startups in this space go to die; software distribution (calendar, mic, MCP, API) is where they compound.

## Privacy / consent models

- **Granola:** invisibility by design. Users love it; workers fear secret surveillance; now a **class action**.
- **Bee:** no-audio-storage, real-time-text-only — the strongest technical privacy story — yet WSJ still judged it "unworthy of the privacy trade-off." **Technical privacy ≠ perceived privacy.**
- **Limitless:** "with consent" positioning; **EU/UK service killed outright** at acquisition — regulators treat always-on voice data as toxic.
- **Plaud:** consent = social, not technical. Reviewers recommend the one-line heads-up: "I've got a recorder running… is that alright?" Explicit capture is socially legible; ambient capture is not.
- **FTC "Active Listening" case** (~May 2026): Cox Media Group + 2 firms paid **$930,000** for falsely claiming AI ad-targeting from smart-device listening *with consumer consent* — the product didn't even listen; the lie about consent was itself the violation.
- **AnswerConnect (2026, 6,000 consumers):** 85% prefer a human over AI; 86% say companies must disclose AI use. **Pew:** half of adults think AI harms relationships.

## Proactive interjection — what happened

- **Friend (shipped):** the only consumer product with true proactive interjection — unprompted texts via "free will." It **interrupted live conversations with unsolicited snarky/insulting messages** (a design choice — "attitude feels more real"). Proactivity without judgment = harassment.
- **Thinking Machines Lab (May 2026):** full-duplex model (simultaneous listening/speaking, interrupts in real time), 0.40s response — **research preview only**.
- **OpenAI GPT-Live-1 (Sep 15, 2026):** full-duplex voice API, 0.798s turn-taking latency, 87% tool-calling accuracy — **developer infrastructure**, not a product.
- **Net (Sep 2026): no shipping consumer product interjects usefully in live human conversation.** The infrastructure just arrived; the product judgment layer does not exist. This is the gap Jev is built for.

## Unsolved hard problems

- **Tech:** the proactivity trigger — calibrating *when* to speak (Friend failed socially; no one has solved it technically); far-field mic quality in noisy rooms; battery for continuous listening; real-time speaker diarization (even desktop is unsolved); on-device vs. cloud; full-duplex latency for natural interjection.
- **UX:** interruption etiquette (what deserves a ping vs. silence?); glanceability without a screen; **recovery from silence** (Granola's blank-session failure); notification norms for a device that hears everything; the "wearing a wire" bystander problem.
- **Social acceptance:** bystander consent at scale; all-party-consent wiretap law (Granola's class action is the warning shot); advertising/public backlash; Pew's relationship-harm perception.
- **Privacy:** data retention defaults (even Pedregal is researching auto-deleting transcripts); training opt-outs; enterprise trust; EU/UK regulatory posture; the gap between technical privacy and perceived privacy.
- **Business model:** minute-metered AI (Plaud) works; subscriptions on cheap hardware (Friend) don't; incumbents absorb rather than compete.

Related: [00-product-one-liner.md](00-product-one-liner.md) · [01-consumer-wedge.md](01-consumer-wedge.md) · [03-jev.md](03-jev.md) · [06-strategic-reads.md](06-strategic-reads.md)
