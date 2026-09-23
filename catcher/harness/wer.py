#!/usr/bin/env python3
"""Normalised word error rate for Catcher P1."""

from __future__ import annotations

import argparse
import re
import sys


def normalize(text: str) -> list[str]:
    text = text.lower().replace("’", "'")
    text = re.sub(r"[^a-z0-9'\s]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return []
    return text.split(" ")


def word_error_rate(reference: str, hypothesis: str) -> float:
    ref = normalize(reference)
    hyp = normalize(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    rows = len(ref) + 1
    cols = len(hyp) + 1
    distance = [[0] * cols for _ in range(rows)]
    for i in range(rows):
        distance[i][0] = i
    for j in range(cols):
        distance[0][j] = j
    for i in range(1, rows):
        for j in range(1, cols):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            distance[i][j] = min(
                distance[i - 1][j] + 1,
                distance[i][j - 1] + 1,
                distance[i - 1][j - 1] + cost,
            )
    return distance[-1][-1] / len(ref)


def main() -> int:
    parser = argparse.ArgumentParser(description="Normalised WER against a reference transcript")
    parser.add_argument("--ref", required=True)
    parser.add_argument("--hyp", required=True)
    parser.add_argument("--threshold", type=float, default=0.15)
    args = parser.parse_args()
    with open(args.ref, encoding="utf-8") as handle:
        reference = handle.read()
    with open(args.hyp, encoding="utf-8") as handle:
        hypothesis = handle.read()
    score = word_error_rate(reference, hypothesis)
    print(f"{score:.4f}")
    return 0 if score <= args.threshold else 1


if __name__ == "__main__":
    sys.exit(main())
