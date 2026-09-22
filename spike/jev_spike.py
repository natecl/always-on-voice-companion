#!/usr/bin/env python3
"""Jev judgment spike — can Jev judge utterances well enough to power the always-on companion?

For each utterance in a transcript, asks Jev 4 parallel Noul (yes/no probability) questions:

  - is_commitment:     the speaker commits to a future action
  - is_deadline:       the utterance sets a time/date by which something must happen
  - is_decision:       the speakers state or reach a decision
  - interrupt_worthy:  a listening AI should interject on this (flag a forgotten
                       commitment, correct an error, surface relevant context)

Why Noul: it returns a calibrated 0..1 probability per question, which is exactly what
we need to test — both accuracy AND calibration of the interjection policy.

Usage:
  export TYPESAFE_API_KEY=...            # from https://typesafe.ai ($5 free on signup)
  python3 jev_spike.py transcript.txt
  python3 jev_spike.py transcript.txt --labels labels.json --out results.json

Transcript format: one utterance per line, "SPEAKER: text". Blank lines are skipped.
Labels format (optional, for grading): JSON list, one entry per utterance, in order:
  [{"commitment": 1, "deadline": 0, "decision": 0, "interrupt_worthy": 0}, ...]

Zero third-party dependencies — stdlib only. Official SDK alternative: pip install typesafe-sdk.
API reference: https://docs.typesafe.ai/api
"""

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error

API_URL = "https://api.typesafe.ai/v1/systemone"
DEFAULT_MODEL = "jev-1.13.0"  # pin for eval reproducibility; override with --model
USD_PER_M_INPUT_TOKENS = 0.042
THRESHOLD = 0.5

QUESTIONS = {
    "is_commitment": (
        "Does the speaker commit to a future action in this utterance?",
        "The speaker promises, agrees to, or assigns a future action (e.g. 'I'll send it tonight').",
        "No commitment is made; it's discussion, a question, or a status update.",
    ),
    "is_deadline": (
        "Does the utterance set a time or date by which something must happen?",
        "A concrete time/date/deadline is stated (e.g. 'by Friday', 'tomorrow at 9').",
        "No time or date constraint is stated.",
    ),
    "is_decision": (
        "Do the speakers state or reach a decision in this utterance?",
        "A choice between options is settled (e.g. 'let's go with the blue one').",
        "Options are still open; no decision is made.",
    ),
    "interrupt_worthy": (
        "Should a listening AI voice buddy interject based on this utterance?",
        "Yes — e.g. flag a forgotten commitment, correct a factual error, or surface "
        "relevant context the speakers clearly need right now.",
        "No — stay quiet; nothing here merits interrupting the conversation.",
    ),
}


def parse_transcript(path):
    utterances = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if ":" in line:
                speaker, text = line.split(":", 1)
                utterances.append({"speaker": speaker.strip(), "text": text.strip()})
            else:
                utterances.append({"speaker": "UNKNOWN", "text": line})
    if not utterances:
        raise SystemExit(f"No utterances found in {path}")
    return utterances


def build_request(utterances, i, model):
    prior = [u["speaker"] + ": " + u["text"] for u in utterances[max(0, i - 2):i]]
    u = utterances[i]
    questions = {}
    for qid, (instructions, yes, no) in QUESTIONS.items():
        questions[qid] = {
            "type": "noul",
            "instructions": instructions,
            "criteria": {"yes": yes, "no": no},
        }
    return {
        "model": model,
        "state": {
            "speaker": u["speaker"],
            "utterance": u["text"],
            "prior_context": prior,
        },
        "questions": questions,
    }


def call_jev(body, api_key, retries=4):
    data = json.dumps(body).encode()
    for attempt in range(retries + 1):
        req = urllib.request.Request(
            API_URL,
            data=data,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
        )
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = json.loads(resp.read())
            return payload, (time.time() - t0) * 1000
        except urllib.error.HTTPError as e:
            if e.code in (429, 529) and attempt < retries:
                time.sleep(2 ** attempt)
                continue
            detail = e.read().decode(errors="replace")[:500]
            raise SystemExit(f"API error {e.code}: {detail}")
    raise SystemExit("API kept rate-limiting; giving up.")


def grade(results, labels):
    cats = ["commitment", "deadline", "decision", "interrupt_worthy"]
    qids = ["is_commitment", "is_deadline", "is_decision", "interrupt_worthy"]
    print("\n=== GRADING (threshold 0.5) ===")
    for cat, qid in zip(cats, qids):
        tp = fp = fn = 0
        for r, lab in zip(results, labels):
            pred = 1 if r["scores"][qid] >= THRESHOLD else 0
            actual = int(lab.get(cat, 0))
            if pred and actual:
                tp += 1
            elif pred and not actual:
                fp += 1
            elif not pred and actual:
                fn += 1
        prec = tp / (tp + fp) if (tp + fp) else 0.0
        rec = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0
        print(f"  {cat:16s} P={prec:.2f} R={rec:.2f} F1={f1:.2f}  (n_pos={tp + fn})")

    print("\n=== CALIBRATION (predicted bin -> actual rate) ===")
    for cat, qid in zip(cats, qids):
        bins = [(0.0, 0.2), (0.2, 0.4), (0.4, 0.6), (0.6, 0.8), (0.8, 1.01)]
        parts = []
        for lo, hi in bins:
            n = sum(1 for r in results if lo <= r["scores"][qid] < hi)
            if n:
                rate = sum(int(lab.get(cat, 0)) for r, lab in zip(results, labels)
                           if lo <= r["scores"][qid] < hi) / n
                parts.append(f"[{lo:.1f}-{hi:.1f}): {rate:.2f} (n={n})")
        print(f"  {cat:16s}" + ("  ".join(parts) if parts else "  no predictions"))


def main():
    ap = argparse.ArgumentParser(description="Jev judgment spike for the always-on companion.")
    ap.add_argument("transcript", help="Transcript file, one 'SPEAKER: utterance' per line")
    ap.add_argument("--labels", help="JSON labels file for grading (see module docstring)")
    ap.add_argument("--out", default="results.json", help="Where to write results JSON")
    ap.add_argument("--model", default=DEFAULT_MODEL, help="Jev model (default: pinned jev-1.13.0)")
    args = ap.parse_args()

    api_key = os.environ.get("TYPESAFE_API_KEY")
    if not api_key:
        raise SystemExit("Set TYPESAFE_API_KEY first (https://typesafe.ai — $5 free on signup).")

    utterances = parse_transcript(args.transcript)
    print(f"Judging {len(utterances)} utterances with {args.model} ...")

    results, total_in, total_lat = [], 0, 0.0
    for i, u in enumerate(utterances):
        payload, latency_ms = call_jev(build_request(utterances, i, args.model), api_key)
        answers = payload.get("answers", {})
        scores = {qid: float(answers[qid]["noul"]) for qid in QUESTIONS}
        usage = payload.get("usage", {}) or {}
        in_tok = usage.get("input_tokens", usage.get("input", usage.get("prompt_tokens", 0)))
        total_in += in_tok
        total_lat += latency_ms
        results.append({
            "i": i,
            "speaker": u["speaker"],
            "text": u["text"][:160],
            "scores": {k: round(v, 3) for k, v in scores.items()},
            "latency_ms": round(latency_ms, 1),
        })
        flags = " ".join(k for k, v in scores.items() if v >= THRESHOLD)
        print(f"  [{i:3d}] {u['speaker']}: {u['text'][:70]}")
        print(f"         -> {', '.join(f'{k}={v:.2f}' for k, v in scores.items())}"
              + (f"   *** {flags}" if flags else ""))

    cost = total_in / 1_000_000 * USD_PER_M_INPUT_TOKENS
    n = len(utterances)
    print(f"\n=== RUN SUMMARY ===")
    print(f"  utterances : {n}")
    print(f"  input toks : {total_in}  (~${cost:.4f} this run)")
    print(f"  cost/1k utt: ${cost / n * 1000:.4f}")
    print(f"  mean latency: {total_lat / n:.0f} ms")

    with open(args.out, "w") as f:
        json.dump({"model": args.model, "results": results,
                   "total_input_tokens": total_in, "est_cost_usd": round(cost, 4)}, f, indent=2)
    print(f"  wrote {args.out}")

    if args.labels:
        with open(args.labels) as f:
            labels = json.load(f)
        if len(labels) != n:
            raise SystemExit(f"Labels ({len(labels)}) != utterances ({n})")
        grade(results, labels)
    else:
        print("\n(no labels file — pass --labels to grade accuracy/calibration)")


if __name__ == "__main__":
    main()
