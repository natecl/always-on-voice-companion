"""Grader logic on synthetic sessions. Tier L: regression only, never P1–P6
evidence. Off a Mac every gate is at best `unproven`; these tests assert the
`checks` list and that no soft-pass shape reaches `pass`."""

from __future__ import annotations

import json
import math
import struct
import sys
import tempfile
import unittest
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS))

import grade  # noqa: E402

REF = HARNESS / "fixtures" / "known-60s.ref.txt"


class Session:
    """A session directory under a temporary harness root."""

    def __init__(self, root: Path, *, engine: str = "grok-voice-transcribe-2.0", app: str = "0.0.1+abc123") -> None:
        self.root = root
        self.dir = root / "11111111-2222-3333-4444-555555555555"
        self.dir.mkdir(parents=True)
        self.rows: list[dict] = [{
            "t": "session",
            "id": "11111111-2222-3333-4444-555555555555",
            "startedAt": "2026-09-23T05:00:00.000Z",
            "engine": engine,
            "tracks": ["system", "microphone"],
            "app": app,
        }]
        self.seq = 0

    def seg(self, track: str, start: int, end: int, text: str, speaker: str | None = None) -> "Session":
        self.seq += 1
        row = {
            "t": "seg", "seq": self.seq, "track": track, "startMs": start, "endMs": end,
            "final": True, "text": text,
            "words": [{"w": word, "s": start, "e": end} for word in text.split()],
        }
        if speaker is not None:
            row["speaker"] = speaker
        self.rows.append(row)
        return self

    def ann(self, at: int, kind: str, detail: object = None) -> "Session":
        row: dict = {"t": "ann", "atMs": at, "kind": kind}
        if detail is not None:
            row["detail"] = detail
        self.rows.append(row)
        return self

    def end(self, at: int, clean: bool = True) -> "Session":
        self.rows.append({"t": "end", "atMs": at, "clean": clean})
        return self

    def pcm(self, track: str, spans: list[tuple[int, int, float]], total_ms: int, dc: int = 0) -> "Session":
        """Square-ish tone with the given AC RMS in each (fromMs, toMs, rms) span."""
        count = total_ms * grade.SAMPLE_RATE // 1000
        samples = [dc] * count
        for start, end, rms in spans:
            amplitude = int(rms * 32768)
            for index in range(start * 16, min(count, end * 16)):
                samples[index] = dc + (amplitude if index % 2 == 0 else -amplitude)
        clipped = [max(-32768, min(32767, value)) for value in samples]
        (self.dir / f"{track}.pcm").write_bytes(struct.pack("<" + "h" * len(clipped), *clipped))
        return self

    def write(self) -> Path:
        text = "\n".join(json.dumps(row) for row in self.rows) + "\n"
        (self.dir / "events.jsonl").write_text(text, encoding="utf-8")
        return self.dir


def run(gate: str, session: Path, **kwargs) -> dict:
    rows, _ = grade.load_rows(session)
    kwargs.setdefault("no_provenance", True)
    return grade.grade_gate(gate, session, rows, **kwargs)


def failed(result: dict) -> set[str]:
    return {str(item["name"]) for item in result["checks"] if not item["ok"]}


def assert_checks_ok_but_unproven(case: unittest.TestCase, result: dict) -> None:
    case.assertEqual(result["result"], "unproven", result["evidence"])
    case.assertEqual(failed(result), {"provenance"}, result["evidence"])


class TempRoot(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def session(self, **kwargs) -> Session:
        return Session(self.root, **kwargs)


class VocabularyTests(TempRoot):
    def test_premise_failure_is_invalid_not_fail(self) -> None:
        gate = grade.Gate()
        gate.check("a", True, "")
        gate.check("b", False, "", grade.GATE_CHECK)
        gate.check("c", False, "", grade.PREMISE_CHECK)
        self.assertEqual(gate.result()["result"], "invalid")

    def test_gate_failure_beats_unproven(self) -> None:
        gate = grade.Gate()
        gate.check("a", False, "")
        gate.check("provenance", False, "", grade.PROVENANCE_CHECK)
        self.assertEqual(gate.result()["result"], "fail")

    def test_no_provenance_never_passes(self) -> None:
        session = self.session().seg("system", 0, 1000, "x", "S1").seg("microphone", 0, 1000, "y").write()
        result = run("P6", session)
        self.assertNotEqual(result["result"], "pass")

    def test_cli_writes_checks_and_exits_nonzero_off_mac(self) -> None:
        import subprocess

        session = self.session().seg("system", 0, 1000, "x", "S1").seg("microphone", 0, 1000, "y").write()
        out = self.root / "grade.json"
        status = subprocess.run(
            [sys.executable, str(HARNESS / "grade.py"), "--session", str(session), "--gate", "P6",
             "--no-provenance", "--out", str(out)],
            capture_output=True, check=False,
        ).returncode
        self.assertEqual(status, 1)
        report = json.loads(out.read_text())
        self.assertIn(report["P6"]["result"], {"unproven", "fail"})
        self.assertTrue(report["P6"]["checks"])
        self.assertEqual(report["P1"]["result"], "n/a")


def harness_run(root: Path, gate: str, **overrides) -> dict:
    record = {
        "gate": gate,
        "startedWallMs": 1790139590000,  # 2026-09-23T04:59:50Z, before the session header
        "host": "Darwin",
        "macOS": "15.3",
        "arch": "arm64",
        "hwModel": "Mac15,3",
        "catcherApp": "/tmp/Catcher.app",
        "catcherGitSHA": "abc123",
        "catcherEngine": "grok",
        "harnessGitSHA": "abc123",
        "codesign": {"cdhash": "deadbeef", "teamIdentifier": "not set", "signature": "", "authority": ["Catcher Development"]},
    }
    record.update(overrides)
    (root / "harness_run.json").write_text(json.dumps(record), encoding="utf-8")
    return record


class OnMac(TempRoot):
    """Grades as if on a Mac so provenance itself is exercised."""

    def setUp(self) -> None:
        super().setUp()
        self._host = grade.platform_system
        grade.platform_system = lambda: "Darwin"

    def tearDown(self) -> None:
        grade.platform_system = self._host
        super().tearDown()


def p6_session(case: TempRoot, **kwargs) -> Path:
    session = case.session(**kwargs)
    session.seg("system", 1000, 4000, "hello from the fixture", "S1")
    session.seg("microphone", 2000, 5000, "and me talking over it")
    session.pcm("microphone", [(2000, 5000, 0.2)], 6000)
    session.pcm("system", [(1000, 4000, 0.2)], 6000)
    return session.write()


class ProvenanceTests(OnMac):
    def test_linux_host_is_unproven(self) -> None:
        grade.platform_system = lambda: "Linux"
        harness_run(self.root, "P6")
        result = run("P6", p6_session(self), no_provenance=False)
        self.assertEqual(result["result"], "unproven")
        self.assertIn("graded-on-mac", failed(result))

    def test_mac_harness_run_with_matching_sha_passes(self) -> None:
        harness_run(self.root, "P6")
        result = run("P6", p6_session(self), no_provenance=False)
        self.assertEqual(result["result"], "pass", result["evidence"])

    def test_missing_harness_run_is_unproven(self) -> None:
        result = run("P6", p6_session(self), no_provenance=False)
        self.assertEqual(result["result"], "unproven")
        self.assertIn("harness-run", failed(result))

    def test_harness_run_for_another_gate_is_unproven(self) -> None:
        harness_run(self.root, "P1")
        self.assertIn("harness-run", failed(run("P6", p6_session(self), no_provenance=False)))

    def test_old_macos_is_unproven(self) -> None:
        harness_run(self.root, "P6", macOS="14.6")
        self.assertIn("macos", failed(run("P6", p6_session(self), no_provenance=False)))

    def test_sha_mismatch_unknown_and_dirty_are_unproven(self) -> None:
        for app, plist in (("0.0.1+abc123", "fff999"), ("0.0.1+unknown", "unknown"), ("0.0.1+abc123-dirty", "abc123-dirty"), ("0.0.1", "")):
            with self.subTest(app=app):
                sub = self.root / app.replace("+", "_")
                sub.mkdir()
                harness_run(sub, "P6", catcherGitSHA=plist)
                case = TempRoot()
                case.root = sub
                result = run("P6", p6_session(case, app=app), no_provenance=False)
                self.assertEqual(result["result"], "unproven", result["evidence"])
                self.assertIn("build-sha", failed(result))

    def test_session_older_than_the_harness_run_is_unproven(self) -> None:
        harness_run(self.root, "P6", startedWallMs=1790139700000)
        self.assertIn("session-after-harness-start", failed(run("P6", p6_session(self), no_provenance=False)))

    def test_missing_cdhash_is_unproven(self) -> None:
        harness_run(self.root, "P6", codesign={"cdhash": "", "signature": "adhoc"})
        self.assertIn("codesign", failed(run("P6", p6_session(self), no_provenance=False)))

    def test_stub_engine_fails_p1_p3_p6(self) -> None:
        session = p6_session(self, engine="stub")
        for gate in ("P1", "P3", "P6"):
            with self.subTest(gate=gate):
                harness_run(self.root, gate)
                result = run(gate, session, ref=REF, no_provenance=False)
                self.assertEqual(result["result"], "fail")
                self.assertIn("engine=grok", failed(result))

    def test_p5_needs_stub_header_and_same_build_grok_reference(self) -> None:
        reference = p6_session(self)
        stub_root = self.root / "p5"
        stub_root.mkdir()
        harness_run(stub_root, "P5", catcherEngine="stub")
        case = TempRoot()
        case.root = stub_root
        stub = p6_session(case, engine="stub")
        self.assertEqual(run("P5", stub, shape_reference=reference, no_provenance=False)["result"], "pass")
        stub_ref = self.root / "stubref"
        stub_ref.mkdir()
        case.root = stub_ref
        self.assertIn("reference-engine", failed(run("P5", stub, shape_reference=p6_session(case, engine="stub"))))
        other = self.root / "other"
        other.mkdir()
        case.root = other
        self.assertIn("reference-same-build", failed(run("P5", stub, shape_reference=p6_session(case, app="0.0.1+fff999"))))
        self.assertIn("shape-reference", failed(run("P5", stub)))
        self.assertIn("engine=stub", failed(run("P5", reference, shape_reference=reference)))


if __name__ == "__main__":
    unittest.main()
