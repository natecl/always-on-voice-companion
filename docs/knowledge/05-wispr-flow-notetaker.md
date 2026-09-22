# Wispr Flow Notetaker — knowledge doc

Deep research pass 2026-09-22 (track 5). The second incumbent on the proven layer — and the one most likely to race us to the buddy.

## What it is

Notetaker launched **Aug 5, 2026** (Mac; Windows has since shipped — "Mac and Windows only for now"). A meeting assistant built into the Wispr Flow app, bot-free OS capture, same invisibility model as Granola.

## Core loop

1. **Pre-meeting brief:** calendar + participant background + context pulled from prior transcripts and connected sources.
2. **Live transcript** with named speaker labels (captures even filler like "mm-hmm"). **Detects calls not on the calendar and asks whether to start** — Meet, Zoom, Teams, WhatsApp, FaceTime, Discord, in-person via mic.
3. **"What did I miss?"** mid-meeting recap button.
4. **Two-pass post-meeting notes:** the full conversation is re-analyzed after the call — correcting live transcription errors, finalizing speaker labels — producing summary, decisions, timelines, tasks, unresolved issues. This is their structural answer to Granola's live-only pass.
5. **Ask Wispr:** meeting-aware chat across history ("meeting history becomes something you can ask questions of" — CTO Sahaj Garg). Preset prompts (Coach me, List recent todos, weekly recap) via a third-party app reference — ⚠️ not confirmed on Wispr's own pages.
6. Covers **voice memos** too, not just meetings.

Also: one-step imports from **Granola and Otter** history; MCP into Claude/ChatGPT/Gemini; notes private / team-visible / link-visible; max recording length configurable to 6 hours.

## Tech — accuracy as the anti-Granola weapon

- **Canto**, their first proprietary ASR, previewed with the Aug round: Kothari claims error rates fall **from >30% to 5–10% of words in the hardest conditions** (noise, wind, accents, music). Much of the $280M raise is earmarked for transcription R&D.
- **Named-speaker diarization** is the marketed differentiator — Wispr's vs-Granola page tells prospects to A/B test both tools on a 3-person Teams call: "does each line carry the person who said it, or a Me and Them split." ⚠️ No independent diarization benchmarks exist (product is ~7 weeks old); one mock-meeting blog scored Wispr highest on transcript accuracy.
- **Dictation heritage:** 100+ language dictation, per-user Dictionary (names/acronyms/replacement rules, auto-learns corrections, shareable on teams), Scratchpad, "zero edit rate" as the internal north-star metric, Flow Sessions (bounded mic-access windows — an ambient-listening primitive).
- **Audio handling:** policy says meeting audio **may be temporarily retained, encrypted, on-device or in cloud — but explicitly not user-accessible, searchable, replayable, or exportable.** So Wispr shares Granola's worst failure mode: if capture silently fails, the meeting is gone.
- Transcription languages for Notetaker: 21 (vs 100+ for dictation).

## Privacy — the trust wound

- **Mandatory Cloud Sync for Notetaker** — no fully local option. "Privacy Mode ≠ local mode."
- **Privacy Mode is opt-out, not opt-in** (enterprise gets training-off-by-default + org enforcement; consumer doesn't).
- The ToS puts the **consent burden on the user** (obtain consents, comply with recording laws).
- **Notetaker + Scratchpad are DISABLED on HIPAA BAA accounts** — regulated workflows locked out.
- **2025 incident** (Fortune Herald + community research): users discovered the app **capturing screenshots and sending audio to cloud servers including third-party API providers**; Wispr's initial response included **banning the user who surfaced it** (CTO later apologized). Privacy Mode and revised training policy followed. This is the wound any competitor can quote.

## Business

- Founded 2021, SF. Exactly **two** founders: **Tanay Kothari** (CEO) + **Sahaj Garg** (CTO), Stanford roommates. (⚠️ "Sahil Agarwal" as third co-founder appears nowhere — treat as wrong.) Started as neurotech/BCI hardware; killed the device after watching Humane/Rabbit crash; pivoted to the voice-dictation software built for the wearable.
- **$361M total raised:** $12M (Sep 2024) → $30M Series A Menlo (Jun 2025) → $25M Notable ext. (Nov 2025, $81M @ $700M) → **$280M Series B at $2B, Menlo-led, announced Aug 17, 2026** (Reuters).
- Traction (company-reported): 2.5M+ downloads, 40–50% MoM, **60B words**, ~all Fortune 500, 10,000+ enterprises, 80% 6-month retention, 19% paid conversion, ~50 employees.
- **Pricing** (verified live 2026-09-22): Free $0 (dictation word caps + **weekly Notetaker meeting limit**); **Pro $15/mo** ($12 annual — higher Notetaker limits + longer history); Growth/Enterprise (unlimited Notetaker add-on, SSO/SCIM, training locked off, signed BAA). **Launch promo: "Notetaker's on us — Free through October 31"** — classic land-grab.

## Head-to-head with Granola

Where they match: bot-free OS capture; live transcript; post-meeting AI notes; calendar workflow; searchable history with source-linked answers; MCP; "notepad, not surveillance" positioning.

Where they diverge: dictation heritage (voice corpus, Dictionary, zero-edit culture); named-speaker diarization vs Granola's Me/Them collapse; two-pass notes vs live-only; imports Granola/Otter (courts defectors, rescues notes locked behind Granola's 30-day free history); Pro $15 vs Business $14; no mobile notetaker.

The one hands-on comparison (same 30-min mock meeting, Wispr vs Granola vs Fathom vs local): **"the closest head-to-head," Wispr "likely having an accuracy edge because its transcript comes from a dictation-grade engine."** Verdict: "Wispr Flow Notetaker is the strongest overall bet for most people… Granola remains a polished, proven alternative." (Single mock meeting — weight accordingly.)

**Plaud** is the third player: Mac notetaker (Jan 2026) with multimodal notes (images + typed alongside transcript), hardware base >1.5M devices (in-person capture neither rival has), minute-metered pricing. All three converge on bot-free desktop capture — the mechanic is commoditizing.

## Loves / hates (⚠️ thin — product is ~7 weeks old)

Notetaker-specific: positive on accuracy and the ask-anything retrieval; cautionary on consent burden ("the bot is gone, but the recording isn't") and human review still needed. **No capture-reliability complaints found yet** — but Granola's took months to accumulate.

The flagship dictation sentiment is richer and mixed: "life-changing," 4.7★ Product Hunt, G2 4.5/5 vs Trustpilot 2.7/5; Wispr itself ran a "call all haters" drive (July 29, 2026 — 700+ respondents, expected ~50); ~800MB RAM idle Electron bloat; 6-min transcription cap; no offline; Windows historically second-class.

## Strategic read

- **Wispr validates the direction, threatens the timeline.** Kothari: meetings give the assistant "additional context about its users" — dictation → meetings → "Jarvis"-style assistant is his stated arc. They are assembling ambient-listening primitives today (auto-detect unlisted calls, Flow Sessions). The dangerous Wispr is 18 months out, not today.
- **But transcription is table stakes, not the product.** Notetaker is still *reactive*: pre-brief, transcript, notes, reactive chat. No "should I speak now?", no interjection, no ambient triage. The Jev judgment layer is untouched by them.
- **The counter-position is judgment, not capture:** Wispr spent $280M to own transcription and ships a better recorder. The open company decides *what the recording means and when to act on it* — which is precisely the Jev-shaped wedge, and the layer Wispr has no demonstrated edge in.
- Kothari's positioning line to steal: > "Nobody reads meeting transcripts. But everyone acts on them."

Related: [02-granola.md](02-granola.md) · [04-always-on-space.md](04-always-on-space.md) · [06-strategic-reads.md](06-strategic-reads.md)
