"""Grader logic for B2 and B4 on synthetic sessions.

Tier L only. `--no-provenance` forces `unproven` when every product check
passes, which is what these tests assert. A `pass` here would be a bug:
nothing in this file is a Mac run.
"""

from __future__ import annotations

import json
import struct
import sys
import tempfile
import unittest
import wave
from datetime import datetime, timezone
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS))

import grade  # noqa: E402
import grade_v1  # noqa: E402

ENGINE = "grok-voice-transcribe-2.0"


def iso(ms: int) -> str:
    stamp = datetime.fromtimestamp(ms / 1000, timezone.utc)
    return stamp.strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(ms % 1000):03d}Z"


def write_wav(path: Path, onset_ms: int = 200) -> None:
    rate = 16000
    count = rate
    onset = rate * onset_ms // 1000
    frames = bytearray()
    for index in range(count):
        # Alternating samples so mean-removed RMS is speech, not a DC offset.
        sample = 0 if index < onset else (8000 if index % 2 == 0 else -8000)
        frames += struct.pack("<h", sample)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(frames)


class Session:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.dir = root / "11111111-2222-3333-4444-555555555555"
        self.dir.mkdir(parents=True)
        self.events: list[dict] = []
        self.latency: list[dict] = []
        self.run: dict = {"gate": "B2", "startedWallMs": 0}

    def add_event(self, row: dict) -> "Session":
        self.events.append(row)
        return self

    def add_latency(self, row: dict) -> "Session":
        self.latency.append(row)
        return self

    def pcm(self) -> "Session":
        (self.dir / "system.pcm").write_bytes(struct.pack("<hh", 1000, -1000))
        return self

    def write(self) -> Path:
        (self.dir / "events.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in self.events),
            encoding="utf-8",
        )
        (self.dir / "latency.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in self.latency),
            encoding="utf-8",
        )
        (self.root / "harness_run.json").write_text(json.dumps(self.run) + "\n", encoding="utf-8")
        return self.dir


def base_events(started_ms: int) -> list[dict]:
    return [
        {
            "t": "session",
            "id": "11111111-2222-3333-4444-555555555555",
            "startedAt": iso(started_ms),
            "engine": ENGINE,
            "tracks": ["system", "microphone"],
            "app": "0.0.1+abc123",
        },
        {
            "t": "seg",
            "seq": 1,
            "track": "system",
            "startMs": 0,
            "endMs": 1000,
            "final": True,
            "text": "hello there",
            "words": [{"w": "hello", "s": 0, "e": 400}],
        },
        {"t": "end", "atMs": 8000, "clean": True},
    ]


def b2_words(shown: int, cap: int, count: int = 100, backlog: int = 0) -> list[dict]:
    rows: list[dict] = []
    partial_words = []
    final_words = []
    for index in range(backlog):
        final_words.append({"w": f"b{index}", "s": 10 + index, "e": 40, "capAtMs": cap})
    for index in range(count):
        start = 5000 + index * 10
        word = {"w": f"w{index}", "s": start, "e": start + 200, "capAtMs": cap, "sentAtMs": cap + 20}
        final_words.append(word)
        partial_words.append({"w": word["w"], "s": start, "e": start + 180, "capAtMs": cap, "sentAtMs": cap + 20})
    rows.append({
        "t": "tx", "track": "system", "seq": 1, "kind": "partial",
        "recvAtMs": shown - 5, "words": partial_words,
    })
    rows.append({"t": "ui", "track": "system", "seq": 1, "shownAtMs": shown})
    rows.append({
        "t": "tx", "track": "system", "seq": 2, "kind": "final",
        "recvAtMs": shown + 400, "words": final_words,
    })
    rows.append({"t": "ui", "track": "system", "seq": 2, "shownAtMs": shown + 500})
    return rows


def b2_session(root: Path, *, lag_ms: int = 100, backlog: int = 0, gap: bool = False, latency: bool = True) -> tuple[Path, Path]:
    play = 1_700_000_000_000
    origin = play
    live = 100
    cap = 5_000
    shown = cap + lag_ms
    session = Session(root)
    session.run = {"gate": "B2", "startedWallMs": play - 10_000, "playWallMs": play}
    for row in base_events(play - 5_000):
        session.add_event(row)
    if gap:
        session.add_event({"t": "ann", "atMs": 1000, "kind": "gap", "detail": {"fromMs": 1, "toMs": 2, "track": "system"}})
    if latency:
        session.add_latency({"t": "clock", "originWallMs": origin, "app": "0.0.1+abc123"})
        session.add_latency({
            "t": "start", "source": "harnessAutoRecord",
            "inputAtMs": -20, "processStartAtMs": -4000,
        })
        session.add_latency({"t": "mark", "name": "live", "atMs": live})
        # First partial is near playback onset. Its words are not the graded set,
        # so it anchors the external clock check without shrinking word lag.
        session.add_latency({
            "t": "tx", "track": "system", "seq": 0, "kind": "partial",
            "recvAtMs": 480, "words": [{"w": "um", "s": 0, "e": 80, "capAtMs": 400}],
        })
        session.add_latency({"t": "ui", "track": "system", "seq": 0, "shownAtMs": 500})
        for row in b2_words(shown, cap, backlog=backlog):
            session.add_latency(row)
    session.pcm()
    wav = root / "fixture.wav"
    write_wav(wav, onset_ms=200)
    return session.write(), wav


def b4_session(
    root: Path,
    *,
    live_at: int = 400,
    session_ahead_of_click: int = 200,
    idle: list[str] | None = None,
    scenario: str = "cold-record",
) -> Path:
    launch = 1_700_000_000_000
    click = launch + 1_000
    origin = click + session_ahead_of_click - 200
    # startedAt is origin-ish: click + session_ahead_of_click when ahead is 200 → click+200.
    started = click + session_ahead_of_click
    session = Session(root)
    session.run = {
        "gate": f"B4-{scenario}",
        "startedWallMs": launch - 1,
        "inputs": [
            {"kind": "launch", "wallMs": launch},
            {"kind": "recordButton", "wallMs": click},
            {"kind": "recordButton", "wallMs": click + 20_000},
        ],
        "idleSocketLines": [] if idle is None else idle,
    }
    for row in base_events(started):
        session.add_event(row)
    session.add_latency({"t": "clock", "originWallMs": origin, "app": "0.0.1+abc123"})
    session.add_latency({"t": "start", "source": "recordButton", "inputAtMs": -10, "processStartAtMs": -5000})
    session.add_latency({"t": "mark", "name": "first-frame", "track": "system", "atMs": 100})
    session.add_latency({"t": "mark", "name": "first-frame", "track": "microphone", "atMs": 120})
    session.add_latency({"t": "mark", "name": "streaming", "track": "system", "atMs": 300})
    session.add_latency({"t": "mark", "name": "streaming", "track": "microphone", "atMs": 350})
    session.add_latency({"t": "mark", "name": "live", "atMs": live_at})
    session.add_latency({"t": "mark", "name": "stop-requested", "source": "recordButton", "atMs": live_at + 1000})
    session.pcm()
    return session.write()


def names(result: dict) -> dict[str, bool]:
    return {check["name"]: bool(check["ok"]) for check in result["checks"]}


class GradeV1Tests(unittest.TestCase):
    def test_v0_gate_list_unchanged(self) -> None:
        self.assertEqual(grade.GATES, ("P1", "P2", "P3", "P4", "P5", "P6"))

    def test_b2_under_two_seconds_is_unproven_off_mac(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session, wav = b2_session(root, lag_ms=100, backlog=4)
            result = grade_v1.grade_gate("B2", session, fixture=wav, no_provenance=True)
        self.assertEqual(result["result"], "unproven")
        checks = names(result)
        self.assertTrue(checks["lag-p95"])
        self.assertTrue(checks["graded-words"])
        self.assertTrue(checks["no-gap"])
        self.assertIn("startBacklog=4", result["evidence"])
        self.assertIn("anchor=word-end", result["evidence"])

    def test_b2_over_two_seconds_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session, wav = b2_session(root, lag_ms=2500)
            result = grade_v1.grade_gate("B2", session, fixture=wav, no_provenance=True)
        self.assertEqual(result["result"], "fail")
        self.assertFalse(names(result)["lag-p95"])

    def test_b2_gap_is_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session, wav = b2_session(root, gap=True)
            result = grade_v1.grade_gate("B2", session, fixture=wav, no_provenance=True)
        self.assertEqual(result["result"], "invalid")
        no_gap = next(check for check in result["checks"] if check["name"] == "no-gap")
        self.assertFalse(no_gap["ok"])
        self.assertEqual(no_gap["kind"], "premise")

    def test_b2_missing_sidecar_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session, wav = b2_session(root, latency=False)
            result = grade_v1.grade_gate("B2", session, fixture=wav, no_provenance=True)
        self.assertEqual(result["result"], "fail")
        self.assertFalse(names(result)["sidecar-present"])

    def test_b4_cold_record_within_five_seconds_is_unproven_off_mac(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            session = b4_session(Path(tmp), live_at=400)
            result = grade_v1.grade_gate("B4", session, scenario="cold-record", no_provenance=True)
        self.assertEqual(result["result"], "unproven")
        checks = names(result)
        self.assertTrue(checks["live-within"])
        self.assertTrue(checks["live-honest"])
        self.assertTrue(checks["inputs≤2"])
        self.assertTrue(checks["idle-no-socket"])
        self.assertTrue(checks["single-start"])
        self.assertTrue(checks["no-session-before-input"])

    def test_b4_over_five_seconds_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            session = b4_session(Path(tmp), live_at=6000)
            result = grade_v1.grade_gate("B4", session, scenario="cold-record", no_provenance=True)
        self.assertEqual(result["result"], "fail")
        self.assertFalse(names(result)["live-within"])

    def test_b4_session_before_the_click_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            session = b4_session(Path(tmp), session_ahead_of_click=-5_000)
            result = grade_v1.grade_gate("B4", session, scenario="cold-record", no_provenance=True)
        self.assertEqual(result["result"], "fail")
        self.assertFalse(names(result)["no-session-before-input"])

    def test_b4_socket_before_the_click_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            session = b4_session(Path(tmp), idle=["Catcher 1 TCP 10.0.0.1:1->api.x.ai:443 (ESTABLISHED)"])
            result = grade_v1.grade_gate("B4", session, scenario="cold-record", no_provenance=True)
        self.assertEqual(result["result"], "fail")
        self.assertFalse(names(result)["idle-no-socket"])


if __name__ == "__main__":
    unittest.main()
