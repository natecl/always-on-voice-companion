# Jev (TypeSafe AI) — knowledge doc

The superpower behind the always-on voice companion. Researched September 2026.

## What it is

**Jev** (typesafe.ai) — a *decision model*, not a text generator. It takes text and returns
structured judgments: **Choice / Score / Noul** outputs with **calibrated probabilities**.
Text-only, 64k context window.

- Founder: Diogo Almeida (ex-OpenAI, InstructGPT).
- Funding: $40M seed led by DCVC, ~$200M valuation.
- Launched Sept 15, 2026; public Sept 20, 2026 ($5 in free credits on signup).

## Pricing & performance

- **$0.042 / M input tokens, output free.**
- **70–500ms** latency (typically ~200ms).
- Access: typesafe.ai directly, plus Vercel AI Gateway and Cloudflare Workers AI.

TypeSafe openly admits it "cannot prove the price is unsubsidized" — pricing risk to watch.

## Why it matters for us

Pincus and Tan's core claim: always-on AI "will just cost $1,000 a month" on frontier models —
that's why no one has built the always-on companion. Jev is literally named after the
**Jevons paradox**: when a resource gets cheap enough, you squander it, and usage explodes.

Jev makes **per-utterance judgment squanderable**:

- Judge every utterance in real time (commitment? deadline? decision? interrupt-worthy?)
  for fractions of a cent instead of dollars.
- Calibrated confidence scores gate the interjection policy — the companion only speaks
  when judgment confidence clears the bar.
- Triage life-context retrieval: Jev decides which emails/texts/past calls are relevant
  before the expensive companion model answers.

Without Jev, continuous judgment is enterprise-priced. With Jev, it's consumer-priced.
That cost collapse is the entire economic unlock for this product.

## Ecosystem note (Sept 2026)

186 builds on madewithjev.com in the first 4 days. Crowded lanes: coding guardrails,
browser agents, model routers, MCP connectors, code review, email triage, ad scoring,
RAG/rerank. **Open lane: voice + per-utterance judgment on transcripts** — nothing there yet.
