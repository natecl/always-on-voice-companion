#!/usr/bin/env python3
"""Synthetic 60-minute events.jsonl for the B3b brief bench.

Not a recording. Seed 20260923. Fictional harbor-outline review, speakers S1 and S2
plus a mic track. No real names, addresses, or private content.

Re-run from the repo root, then commit the jsonl with this script:

    python3 catcher/harness/fixtures/generate_known_60min.py
"""

import json
from pathlib import Path

SEED_NOTE = "20260923"
SEGMENT_COUNT = 820
DURATION_MS = 3_600_000
GAP_FROM_MS = 1_200_000
GAP_TO_MS = 1_206_000

SPECIAL = {
    40: "We decided the review happens on Friday this week.",
    41: "I will bring the printed checklist to the table.",
}


def utterance(index: int) -> str:
    if index in SPECIAL:
        return SPECIAL[index]
    point = index + 1
    return f"Point {point} covers the harbor outline and the shared checklist today."


def main() -> None:
    root = Path(__file__).resolve().parent
    out = root / "known-60min.events.jsonl"
    rows = [
        {
            "t": "session",
            "id": "synthetic-60min",
            "startedAt": "2026-09-23T00:00:00.000Z",
            "engine": "synthetic",
            "tracks": ["system", "microphone"],
            "app": "0.0.1+synthetic",
        }
    ]
    words = 0
    for index in range(SEGMENT_COUNT):
        start = index * DURATION_MS // SEGMENT_COUNT
        text = utterance(index)
        words += len(text.split())
        if index % 2 == 0:
            track = "microphone"
            speaker = None
        elif index % 4 == 1:
            track = "system"
            speaker = "S1"
        else:
            track = "system"
            speaker = "S2"
        row = {
            "t": "seg",
            "seq": index + 1,
            "track": track,
            "startMs": start,
            "endMs": start + 1_500,
            "final": True,
            "text": text,
            "words": [],
        }
        if speaker is not None:
            row["speaker"] = speaker
        rows.append(row)
        if start >= GAP_FROM_MS and rows[-2].get("kind") != "gap" and not any(
            item.get("kind") == "gap" for item in rows
        ):
            rows.insert(
                -1,
                {
                    "t": "ann",
                    "atMs": GAP_FROM_MS,
                    "kind": "gap",
                    "detail": {"fromMs": GAP_FROM_MS, "toMs": GAP_TO_MS, "track": "system"},
                },
            )
    rows.append({"t": "end", "atMs": DURATION_MS, "clean": True})
    if words < 9_000:
        raise SystemExit(f"word count {words} is under 9000")
    payload = "".join(json.dumps(row, separators=(",", ":"), ensure_ascii=True) + "\n" for row in rows)
    out.write_text(payload, encoding="utf-8")
    print(f"wrote {out.name}: {len(rows)} rows, {words} words, {out.stat().st_size} bytes, seed {SEED_NOTE}")


if __name__ == "__main__":
    main()
