# Granola — knowledge doc

Deep research pass 2026-09-22. Granola is the **proven** we're copying (see `granola-baseline.md`) — and the first of two incumbents the proven slice must beat.

## The product loop

1. **Calendar-driven:** open a note from your calendar for an upcoming meeting.
2. **Live capture:** live transcript behind a waveform icon — grey bubbles = system audio ("Them"), green bubbles = mic ("Me").
3. **Rough notes while listening:** messy typed notes merge with the transcript.
4. **Auto-enhance:** notes become summary + action items + decisions + deadlines. **AI text renders in gray; every AI sentence links back to the exact transcript moment** (the verifiability mechanic).
5. **Ask Granola:** chat across meetings and folders.

Surface: templates, Recipes (repeatable AI workflows), pre-meeting briefs, follow-up email drafting, shared folders, Spaces (team workspaces, Mar 2026), MCP server (Feb 2026), APIs, Notion/Slack/HubSpot integrations.

**The positioning insight** (Bisola Otiko, Medium, Jun 2026):

> "Granola did not just sell 'AI meeting notes.' It sold the ability to stay present without making the meeting weird."

Framed as a *notepad* — "A notepad feels familiar. It feels personal." Copy the framing, not just the features.

## Tech stack

- **Bot-free OS capture** (macOS: Microphone + Screen & System Audio permissions). Audio **streamed live, never stored** — no playback, no file import. Invisible to other parties — and the root of its worst failure mode.
- **Transcription:** Deepgram + AssemblyAI run in parallel; notes via OpenAI/Anthropic (Vanta trust-center subprocessor list). Early on, transcription was "half of our burn rate" (Sam Stephenson).
- **Speaker labels:** desktop = Me/Them only. Named speakers only via Google Meet extension / Zoom integration; mobile in-person capture is ahead of desktop.
- **Training on by default** — opt-out is forward-only (no retroactive deletion). Enterprise gets org-wide opt-out.

## Business

- **Pricing** (verified live on granola.ai/pricing, 2026-09-22): Basic **$0** (30-day history); Business **$14/user/mo** (unlimited history, advanced models, integrations, API, MCP); Enterprise **$35/user/mo** (SSO, SCIM, HIPAA workspaces, org-wide training opt-out, audit API).
- **Founders:** Chris Pedregal (CEO; ex-Google APM; Socratic → acquired by Google 2018) + Sam Stephenson (designer). Founded Mar 2023, London; launched May 22, 2024.
- **Funding:** ~$192M total — Seed $4.25M (May 2023) → Series A $20M (Oct 2024) → Series B $43M @ $250M (May 2025) → **Series C $125M @ $1.5B (Mar 2026)**.
- **Traction:** revenue through mid-Mar 2026 = 2.5× all of 2025 (The Times). Customers: Vanta, Gusto, Thumbtack, Asana, Cursor, Lovable, Decagon, Mistral AI. ⚠️ Headcount reported as ~55 (Times), ~80 (Pedregal), ~116 (Latka) — use as range.

## What users love

> "best meeting notes of anything I've tried" — **Nat Friedman** (X, Jun 2024; quote embedded on Granola's pricing page)

> "feels like living in the future" — **John Borthwick** (Betaworks)

> "The addiction is real." — **Adriana Vitagliano** (Firstminute)

> "(The app's surprisingly good summaries were ultimately what prompted me to become a paying customer.)" — **Casey Newton** (Platformer)

- "People love Granola's usability and looks. For private, internal meetings, it's just clean enough not to cause trouble." (HappyScribe review, Sep 2026)
- The framing itself is the love: stay present, feel personal, not surveillance.

## What users hate

1. **Silent capture failure — the #1 complaint.** "Appeared to be recording and was not, with no error and no alert." One founder: "the app was open all day and produced notes for about 60% of calls." Structural trap: no participant view (bot-free), no audio kept, no import — **"If the session never started, the meeting is gone."**

   > "A generic summary can be edited. A blank session cannot."

2. **Weak speaker ID:** "In a three-person call, two people collapse into Them, and action items lose their owner."
3. **Accuracy ceiling:** ~95% in a quiet room; "add a bad laptop mic, a thick accent, or three people talking over each other, and you will be fixing names and technical terms."
4. **Free tier is a demo:** "The free tier is a taste, not a tool." 30-day history lock hits paywall before full evaluation.
5. **Platform gaps:** Mac/iPhone/Windows only; no web; Google-calendar-centric ("doesn't work for Microsoft Outlook" — capture works, calendar integration is Google-tied).
6. **Privacy trust gap:** "'Private by default' is a good start, not a guarantee." Link-sharing defaults + training opt-out anger privacy users.
7. **Brittle capture:** headphones, virtual audio devices, permissions, battery drain.
8. **Enterprise tax:** auto-deletion, usage analytics, admin controls sit behind the $35 tier.

## Structural weaknesses (gaps to exploit)

- **Chamberlain v. Granola**, N.D. Cal., filed **Jul 30, 2026**, Case No. 3:26-cv-07926-EMC — wiretap/all-party-consent (invisible capture) + default model-training claims, **$5,000/violation**. The invisibility users love is the same property that creates legal risk.
- **No audio retention / no import** = no recovery from any failure.
- **Training-on-by-default** — an always-on competitor differentiates with training-off-by-default + verifiable local processing.
- Early-2026 local-storage change broke on-device AI agent workflows (incl. an a16z partner) — developers want local access.

## Founders' roadmap

- Fight for the daily interface ("a few apps people use all day"); agentic automation of meeting admin; a memory/identity layer over work life.
- "Granola notes are private by default, and 'companies hate us for this.' CEOs regularly ask for access to every employee transcript, and Granola refuses." — Pedregal
- Researching **auto-deleting verbatim transcripts** while compressing knowledge into working memory — i.e., what we should ship before they do.

Related: `granola-baseline.md` · [00-product-one-liner.md](00-product-one-liner.md) · [05-wispr-flow-notetaker.md](05-wispr-flow-notetaker.md) · [06-strategic-reads.md](06-strategic-reads.md)
