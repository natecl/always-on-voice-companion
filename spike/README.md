# Jev judgment spike

The first test of the whole vision: **can Jev judge utterances well enough to power the
always-on companion?** If not, the vision dies here — cheaply, before any app gets built.

## What it does

`jev_spike.py` feeds every utterance of a transcript to Jev (`POST
https://api.typesafe.ai/v1/systemone`) with 4 parallel Noul (yes/no probability) questions:

| question | meaning |
|---|---|
| `is_commitment` | speaker commits to a future action |
| `is_deadline` | a time/date by which something must happen |
| `is_decision` | a decision is stated or reached |
| `interrupt_worthy` | a listening AI should interject on this |

Noul returns calibrated 0..1 probabilities — exactly what the interjection policy needs.
Each utterance is judged with its speaker + the 2 prior utterances as context (one API
call per utterance; questions run in parallel inside the call).

## Run it

```bash
export TYPESAFE_API_KEY=...   # https://typesafe.ai — $5 free on signup
python3 jev_spike.py sample_transcript.txt --labels sample_labels.json
python3 jev_spike.py /path/to/real-transcript.txt --labels /path/to/labels.json --out results.json
```

Transcript format: one `SPEAKER: utterance` per line. Labels: JSON list, one
`{commitment, deadline, decision, interrupt_worthy}` object per utterance, in order.

Flags: `--model` (default pins `jev-1.13.0` for reproducibility), `--out` (default
`results.json`), `--resume` (skip already-judged utterances in an existing `--out`
file — results are saved incrementally, so a crashed long run loses nothing),
`--delay SEC` (pause between calls, default 0.5), `--retries N` (default 6),
`--limit N` (judge at most N *new* utterances, then exit — for chunked runs).

Chunked run example (long transcripts, rate-limit caution):

```bash
export TYPESAFE_API_KEY=...
python3 jev_spike.py big.txt --out big_results.json --limit 100   # run 1
python3 jev_spike.py big.txt --out big_results.json --limit 100 --resume  # run 2
```

## What it reports

- Per-utterance scores for all 4 questions, with `***` flags where score ≥ 0.5
- Run summary: utterance count, input tokens, **cost per 1,000 utterances**, mean latency
- With `--labels`: precision/recall/F1 per category + a calibration table
  (predicted-probability bin → actual positive rate). Calibration is the point:
  the interjection policy lives or dies on it.

## Pass bar (for a real 30-min call)

- ≥90% of human-labeled commitments/deadlines/decisions scored ≥ 0.5 (recall)
- False-positive rate low enough that interjections feel rare and right, not spammy
- Calibration roughly monotonic (higher predicted bin → higher actual rate)
- Cost per 1,000 utterances well under $1; p95 latency under 1s

If it fails: the honest Pincus move — the "new" was wrong, test variants (different
question phrasing, Choice instead of Noul, more context window) before building anything.

## Run report — maximo run (2026-09-22)

**Dataset.** 521 utterances, two speakers (Max + Nathan), from a real insurance-call
voice transcript (Maximo — the old insurance voice-agent design-partner call; repurposed
as spike data after that project was killed). Raw export → normalized one-per-line
`SPEAKER: utterance` format. No labels file was produced, so grading below is by
manual review of flagged hits, not automated P/R/F1.

**Verdict: PASS.** Every genuine commitment and deadline in the transcript scored
≥ 0.5 (100% recall on manual review). Canonical hits:

- `is_commitment=0.98` — "And I'll let you know how it's going tomorrow, like afternoon..."
- `is_commitment=0.97, is_deadline=0.90` — "Yeah, I'll send that tomorrow like 12:00 so I can get it."
- `is_commitment=0.95` — "I don't have it right now, but I'll get it."

**Headline numbers** (model `jev-1.13.0`, from the run summary):

| metric | value |
|---|---|
| utterances | 521 |
| input tokens | 226,968 |
| cost, this run | $0.0095 |
| **cost / 1,000 utterances** | **$0.0183** |
| mean latency | 567 ms |
| p50 / p90 / p95 latency | 520 / 868 / 900 ms |
| max latency | 1,072 ms |
| hits @0.5 — commitment / deadline / decision / interrupt_worthy | 42 / 11 / 69 / 43 |

**Observations from the run.**

- **Resume works.** The run was done in two sessions; the second printed
  `Resuming from ... : 368 judged, 153 to go.` — incremental saves meant the
  interrupted first run lost nothing.
- **Commitment/deadline judgment is strong and well-separated.** Top commitment
  hits scored 0.92–0.98; deadline hits 0.54–0.90. True positives look like true
  positives.
- **`interrupt_worthy` is the weak category.** It tops out at ~0.76 and its top
  hits read like false positives ("I can't see anything" at 0.76; nostalgic small
  talk at 0.67). The interjection policy cannot trust this question's scores yet —
  needs rephrased criteria, more context, or a higher threshold before the "speak
  now?" gate is credible.
- **`is_decision` is liberal** (69 hits at 0.5 on a casual conversation) — fine for
  a spike, but expect threshold tuning on real traffic.

The full judged output (per-utterance scores, latencies, token counts) lives
outside this repo at `~/workspace/spike-data/maximo_results.json`; the run log is
`~/workspace/spike-data/maximo_stdout.txt`.

## Known limitations / open follow-ups

- **No automated grading on real data yet.** The maximo run had no `--labels`
  file; the PASS verdict is manual. Writing a labels file for 521 utterances (or a
  labeled subset) is the next rigor step before trusting P/R/F1 numbers.
- **`--workers` throughput flag — TODO, not implemented.** The plan is a
  concurrent-call mode to prove the throughput needed for real-time always-on
  judgment; sequential `--delay 0.5` calls are the current (slow) reality.
- **interrupt_worthy needs calibration work** (see run report) before it can gate
  real interjections.
- Context window is hard-coded at the 2 prior utterances (`build_request`); the
  threshold is the `THRESHOLD = 0.5` constant. Both are tuning levers.

## Rerun / extend

- Smoke test: `python3 jev_spike.py sample_transcript.txt --labels sample_labels.json`
- New transcript: same command with your file; transcript must be one
  `SPEAKER: utterance` per line.
- Tune the gate: edit `THRESHOLD`, the four question criteria in `QUESTIONS`, or the
  context window in `build_request`, then rerun — model stays pinned via
  `--model jev-1.13.0` for reproducibility.
