"""B3 grader on synthetic sessions. Tier L only. A Linux run is never a pass."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS))

import b3_grade  # noqa: E402

GOLDEN = HARNESS.parent / "Tests" / "BriefTests" / "Golden"
SAMPLE_BRIEF = {
    "schema": "catcher.brief/1",
    "sessionId": "session",
    "createdAt": "2026-09-23T11:02:07.412Z",
    "source": {
        "eventsSha256": "abc",
        "segmentCount": 4,
        "wordCount": 40,
        "durationMs": 3_541_000,
        "clean": True,
        "recovered": False,
    },
    "engine": {"name": "grok-notes", "model": "pinned-later", "promptVersion": "brief-v1"},
    "latency": {},
    "usage": {"inputTokens": 10, "outputTokens": 2},
    "cost": None,
    "title": "Q4 pricing review with Acme",
    "blocks": [
        {"id": "summary", "kind": "summary", "heading": "Summary", "items": [
            {"text": "Acme will pilot the Team plan in October.", "cites": [41, 57]},
        ]},
        {"id": "topic-1", "kind": "topic", "heading": "Pricing", "items": [
            {"text": "The pilot covers one workspace.", "cites": [12]},
        ]},
        {"id": "decisions", "kind": "decisions", "heading": "Decisions", "items": [
            {"text": "The review date is Friday.", "cites": [88]},
        ]},
        {"id": "next", "kind": "actionItems", "heading": "Next steps", "items": [
            {"text": "Send the pilot contract", "cites": [201], "owner": "me", "due": "Friday"},
        ]},
    ],
    "caveats": ["Transcript gap 00:41\u201300:47 (network)."],
}


def check(result: dict, name: str) -> dict:
    matches = [item for item in result["checks"] if item["name"] == name]
    if not matches:
        raise AssertionError(f"no check {name} in {result['checks']}")
    return matches[0]


class RendererTests(unittest.TestCase):
    def test_markdown_and_html_match_the_swift_golden_files(self) -> None:
        self.assertEqual(b3_grade.render_markdown(SAMPLE_BRIEF), (GOLDEN / "sample.md").read_text(encoding="utf-8"))
        self.assertEqual(b3_grade.render_html(SAMPLE_BRIEF), (GOLDEN / "sample.html").read_text(encoding="utf-8"))
        self.assertNotIn("Transcript gap", b3_grade.render_markdown(SAMPLE_BRIEF))
        self.assertIn("Notes by Catcher", b3_grade.render_markdown(SAMPLE_BRIEF))


class GradeTests(unittest.TestCase):
    def test_product_checks_pass_and_linux_stays_unproven(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            observe = self.write_run(root)
            result = b3_grade.grade_b3(root, observe, no_provenance=True)
        self.assertEqual(result["result"], "unproven")
        for name in ("schema", "cites", "shareable", "copy", "untouched", "engine", "latency", "long"):
            self.assertTrue(check(result, name)["ok"], name)
        self.assertFalse(check(result, "provenance")["ok"])

    def test_latency_over_thirty_seconds_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            observe = self.write_run(root, latency_ms=31_000)
            result = b3_grade.grade_b3(root, observe, no_provenance=True)
        self.assertEqual(result["result"], "fail")
        self.assertFalse(check(result, "latency")["ok"])

    def test_long_stage_plus_stop_overhead_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            observe = self.write_run(root, assemble_ms=15_000, stage_ms=20_000)
            result = b3_grade.grade_b3(root, observe, no_provenance=True)
        self.assertEqual(result["result"], "fail")
        self.assertFalse(check(result, "long")["ok"])

    def test_bad_cite_stub_engine_and_copy_mismatch_fail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            observe = self.write_run(root, cite=99, notes_engine="stub", header_engine="stub", paste="nope")
            result = b3_grade.grade_b3(root, observe, no_provenance=True)
        self.assertEqual(result["result"], "fail")
        self.assertFalse(check(result, "cites")["ok"])
        self.assertFalse(check(result, "engine")["ok"])
        self.assertIn("stub engine cannot prove B3", check(result, "engine")["detail"])
        self.assertFalse(check(result, "copy")["ok"])

    def test_caveat_in_the_copy_fails_shareable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            observe = self.write_run(root, leak_caveat=True)
            result = b3_grade.grade_b3(root, observe, no_provenance=True)
        self.assertEqual(result["result"], "fail")
        self.assertFalse(check(result, "shareable")["ok"])

    def test_events_hash_drift_fails_untouched(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            observe = self.write_run(root, tamper_events=True)
            result = b3_grade.grade_b3(root, observe, no_provenance=True)
        self.assertEqual(result["result"], "fail")
        self.assertFalse(check(result, "untouched")["ok"])

    def test_network_error_is_invalid_not_a_product_fail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            observe = self.write_run(root, network=True)
            result = b3_grade.grade_b3(root, observe, no_provenance=True)
            self.assertTrue((root / "s1" / "brief-error.json").is_file())
        self.assertEqual(result["result"], "invalid")
        self.assertEqual(check(result, "network")["kind"], "premise")

    def test_fewer_than_three_sessions_is_invalid(self) -> None:
        result = b3_grade.grade_b3(Path("/tmp"), {"sessions": [], "long": {"runs": []}}, no_provenance=True)
        self.assertEqual(result["result"], "invalid")

    def write_run(
        self,
        root: Path,
        *,
        latency_ms: int = 1_000,
        assemble_ms: int = 400,
        stage_ms: int = 1_000,
        cite: int = 1,
        notes_engine: str = "grok-notes",
        header_engine: str = "grok-voice-transcribe-2.0",
        paste: str | None = None,
        leak_caveat: bool = False,
        tamper_events: bool = False,
        network: bool = False,
    ) -> dict:
        sessions = []
        for index in range(1, 4):
            directory = root / f"s{index}"
            directory.mkdir()
            events = "\n".join([
                json.dumps({
                    "t": "session",
                    "id": f"s{index}",
                    "startedAt": "2026-09-23T05:00:00.000Z",
                    "engine": header_engine,
                    "tracks": ["microphone"],
                    "app": "0.0.1+abc123",
                }),
                json.dumps({
                    "t": "seg",
                    "seq": 1,
                    "track": "microphone",
                    "startMs": 0,
                    "endMs": 1000,
                    "final": True,
                    "text": "hello there",
                    "words": [],
                }),
                json.dumps({"t": "end", "atMs": 1000, "clean": True}),
            ]) + "\n"
            (directory / "events.jsonl").write_text(events, encoding="utf-8")
            (directory / "session.json").write_text("{}\n", encoding="utf-8")
            (directory / "transcript.txt").write_text("[me] hello there\n", encoding="utf-8")
            events_hash = hashlib.sha256((directory / "events.jsonl").read_bytes()).hexdigest()
            session_hash = hashlib.sha256((directory / "session.json").read_bytes()).hexdigest()
            transcript_hash = hashlib.sha256((directory / "transcript.txt").read_bytes()).hexdigest()
            if network and index == 1:
                (directory / "brief-error.json").write_text(
                    json.dumps({"schema": "catcher.brief/1", "error": "transport reset", "attempts": 1}) + "\n",
                    encoding="utf-8",
                )
            else:
                brief = {
                    "schema": "catcher.brief/1",
                    "sessionId": f"s{index}",
                    "createdAt": "2026-09-23T05:00:01.000Z",
                    "source": {
                        "eventsSha256": "tampered" if tamper_events else events_hash,
                        "segmentCount": 1,
                        "wordCount": 2,
                        "durationMs": 60_000,
                        "clean": True,
                        "recovered": False,
                    },
                    "engine": {"name": notes_engine, "model": "grok-4.20-0309-non-reasoning"},
                    "latency": {},
                    "usage": {"inputTokens": 1, "outputTokens": 1},
                    "cost": None,
                    "title": "Hello",
                    "blocks": [{
                        "id": "summary",
                        "kind": "summary",
                        "heading": "Summary",
                        "items": [{"text": "Hello there.", "cites": [cite]}],
                    }],
                    "caveats": ["Transcript gap 00:00\u201300:01 (system)."],
                }
                markdown = b3_grade.render_markdown(brief)
                if leak_caveat:
                    markdown += brief["caveats"][0] + "\n"
                (directory / "brief.json").write_text(json.dumps(brief) + "\n", encoding="utf-8")
                (directory / "brief.md").write_text(markdown, encoding="utf-8")
            stop = 1_000_000
            sessions.append({
                "directory": str(directory),
                "stopSentWallMs": stop,
                "observedWallMs": stop + latency_ms,
                "assembledWallMs": stop + assemble_ms,
                "eventsSha256AtAssembled": events_hash,
                "sessionJsonSha256AtAssembled": session_hash,
                "transcriptSha256AtAssembled": transcript_hash,
                "pbpaste": paste if paste is not None else (directory / "brief.md").read_text(encoding="utf-8") if (directory / "brief.md").is_file() else "",
                "pasteboardTypes": ["public.utf8-plain-text", "public.html"],
                "html": b3_grade.render_html(json.loads((directory / "brief.json").read_text(encoding="utf-8"))) if (directory / "brief.json").is_file() else "",
            })
        return {
            "sessions": sessions,
            "long": {"runs": [{"totalMs": stage_ms, "outcome": "ready"} for _ in range(3)]},
        }


if __name__ == "__main__":
    unittest.main()
