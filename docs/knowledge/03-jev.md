# Jev / TypeSafe AI — knowledge doc

Deep research pass 2026-09-22. Jev is the **10x lever** for the whole product: per-utterance judgment at consumer price. Complements `jev.md`.

## The company

- **TypeSafe AI**, San Francisco. Founded 2024; out of stealth **Sep 15, 2026** (typesafe.ai).
- Founders: **Diogo Almeida** (CEO; ex-OpenAI, co-inventor of RLHF, InstructGPT co-author), **Erik Gafni** (CTO; Ravel/Invitae/Freenome), **Sasha Sheng** (COO; ex-Meta/FAIR).
- **$40M seed led by DCVC.**

## The model

- **"System One" non-generative decision model** (Kahneman) — never generates text. Three typed primitives: **Noul** (calibrated yes/no 0–1), **Choice** (≤255 options, full distribution + confidence), **Score** (ordinal rubric, distribution + confidence).
- Trained with **RLCD (Reinforcement Learning for Calibrated Decisions)**; confidence is a calibrated signal, distinct from probability.
- "Can't hallucinate" = structurally schema-bound (**0% type errors**) — but **it can still be wrong**. Named after the **Jevons paradox**.
- **Text-only** — no audio/images/video. Architecture must be ASR → text state → Jev judgment → action.

## API surface

- `POST https://api.typesafe.ai/v1/systemone` with `{state, model, questions}`; any mix of questions evaluated **in parallel, in isolation, in one pass**.
- SDKs: Python (`pip install typesafe-sdk`), JS (`npm install @typesafe-ai/sdk`); `TYPESAFE_API_KEY`. Also on Vercel AI Gateway (`typesafe-ai/jev`) and Cloudflare Workers AI (`typesafe/jev`), no waitlist.
- Aliases `jev-latest` / `jev-preview` both resolve to **`jev-1.13.0`** (Sep 2026) — pin the version for evaluation reproducibility.

## Economics — the Jevons-paradox enabler

- **$0.042/M input tokens ($42/B); output free (unmetered).** A 2,000-token routing call ≈ $0.000084.
- **70–500ms** latency (typically ~200ms).
- This is why always-on judgment is newly viable: per-utterance decisions for fractions of a cent instead of dollars. Pincus/Tan's cost thesis — "will just cost $1,000 a month" on frontier models — is what Jev breaks.

## What it's for in our product

The **proactivity trigger** — the layer nobody has built:

- **"Should I speak now?" gates**: Noul on whether, Choice on what action, Score on urgency — calibrated confidence gates the interjection policy. Friend proved unprompted AI reads as creepy; calibrated judgment is the difference.
- **Per-utterance triage**: commitment? deadline? decision? interrupt-worthy? — every utterance judged live.
- **Life-context triage**: which emails/texts/past calls are relevant before the expensive companion model answers.
- **Interruptibility score** — the metric Granola never attempted.

## Spike result (2026-09-22) — validated, PASS

Harness `spike/jev_spike.py` judged a real 521-utterance conversation transcript (branch `spike/jev-judgment-harness`):

- **100% recall on real commitments/deadlines @0.5** — scores 0.85–0.98 (e.g. "send you the runner script tomorrow around 12:00" 0.90; "I'll text you tomorrow night" 0.97; "in like a day or two" 0.90). Filler ("yeah yeah") scored 0.03–0.20.
- **$0.0182 per 1,000 utterances**; mean latency 567ms, p95 900ms.
- Soft spot: `interrupt_worthy` is directionally right (peaks on questions/confusion) but fires on some random stories — needs real product data. That's the "expect it wrong first" part.
- Raw results: `~/workspace/spike-data/maximo_results.json` (521 judged). API key `jev-spike-2` via `TYPESAFE_API_KEY` env (first key truncated-captured and revoked).

## Open diligence items

- ⚠️ **Commercial-use / ToS terms not verified** — no dedicated terms page found. Check before building production on it. Homepage FAQ "Are these prices temporary or subsidized?" answer not captured.
- ⚠️ Benchmarks are **vendor's own, self-run and unreproduced** (193.6× faster, 444.6× cheaper). Independent 791-decision test (ayautomate, Sep 19, 2026) exists — full results not captured.
- ⚠️ Rate limits **disputed**: third-party lists 250,000 tokens/second + 1,200 req/min ("subject to change"); docs publish none. Treat as provisional.

Related: `jev.md` · [00-product-one-liner.md](00-product-one-liner.md) · [04-always-on-space.md](04-always-on-space.md) · [06-strategic-reads.md](06-strategic-reads.md)
