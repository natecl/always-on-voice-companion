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
`--delay SEC` (pause between calls, default 0.5), `--retries N` (default 6).

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
