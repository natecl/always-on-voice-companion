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


def noaudio(at: int = 10000, emitted: int | None = 10000, observed: int = 0, detail: str = "RMS≈0 for >10s on microphone,system") -> str:
    text = detail
    if emitted is not None:
        text += f" emittedAtMs={emitted}"
    return text + f" observedFromMs={observed}"


def p4_session(case: TempRoot, *, mic: list[tuple[int, int, float]] | None = None, system_rms: float = 0.0,
               ann: str | None = None, at: int = 10000, total_ms: int = 16000, **kwargs) -> Session:
    session = case.session(**kwargs)
    session.ann(at, "noAudio", ann if ann is not None else noaudio(at=at))
    session.pcm("microphone", mic or [(0, total_ms, 0.018)], total_ms)
    session.pcm("system", [(0, total_ms, system_rms)] if system_rms else [], total_ms)
    return session


class P4Tests(TempRoot):
    def test_quiet_room_with_live_capture_and_prompt_emission_has_all_checks_ok(self) -> None:
        assert_checks_ok_but_unproven(self, run("P4", p4_session(self).end(16000).write()))

    def test_backdated_noaudio_is_fail(self) -> None:
        result = run("P4", p4_session(self, ann=noaudio(emitted=25000)).write())
        self.assertEqual(result["result"], "fail")
        self.assertIn("emitted-in-time", failed(result))

    def test_missing_emission_time_is_fail(self) -> None:
        result = run("P4", p4_session(self, ann=noaudio(emitted=None)).write())
        self.assertEqual(result["result"], "fail")
        self.assertIn("emitted-in-time", failed(result))

    def test_no_frames_noaudio_is_fail(self) -> None:
        session = self.session().ann(10000, "noAudio", noaudio(detail="no frames for >10s")).write()
        result = run("P4", session)
        self.assertEqual(result["result"], "fail")
        self.assertTrue({"capture-live", "system-pcm", "microphone-pcm"} <= failed(result))

    def test_short_pcm_is_fail(self) -> None:
        result = run("P4", p4_session(self, total_ms=4000).write())
        self.assertIn("microphone-pcm", failed(result))

    def test_quiet_speech_under_the_verifier_floor_is_invalid(self) -> None:
        result = run("P4", p4_session(self, mic=[(0, 16000, 0.018), (2000, 6000, 0.04)]).write())
        self.assertEqual(result["result"], "invalid")
        self.assertIn("quiet-microphone", failed(result))

    def test_unmuted_output_is_invalid(self) -> None:
        result = run("P4", p4_session(self, system_rms=0.01).write())
        self.assertEqual(result["result"], "invalid")
        self.assertIn("system-muted", failed(result))

    def test_window_is_measured_from_capture_start(self) -> None:
        late = p4_session(self, at=14000, ann=noaudio(at=14000, emitted=14000, observed=4000), total_ms=12000).write()
        assert_checks_ok_but_unproven(self, run("P4", late))
        self.assertIn("noaudio-in-window", failed(run("P4", late, silence_at=0)))

    def test_seg_or_flowing_heartbeat_before_emission_is_fail(self) -> None:
        seg = p4_session(self).seg("microphone", 3000, 4000, "hello")
        self.assertIn("no-seg-before-emission", failed(run("P4", seg.write())))
        other = self.root / "hb"
        other.mkdir()
        case = TempRoot()
        case.root = other
        heartbeat = p4_session(case).ann(8300, "degraded", "no engine event for 8000ms while audio is flowing track=microphone emittedAtMs=8300")
        self.assertIn("no-flowing-heartbeat", failed(run("P4", heartbeat.write())))


class NoAudioOverSpeechTests(TempRoot):
    def test_noaudio_over_quiet_speech_fails_p6_and_p1(self) -> None:
        session = self.session()
        session.seg("system", 1000, 4000, "hello from the fixture", "S1").seg("microphone", 2000, 5000, "me")
        session.ann(10000, "noAudio", noaudio())
        session.pcm("microphone", [(2000, 8000, 0.04)], 12000)
        session.pcm("system", [], 12000)
        path = session.write()
        for gate in ("P6", "P1"):
            with self.subTest(gate=gate):
                result = run(gate, path, ref=REF)
                self.assertEqual(result["result"], "fail")
                self.assertIn("no-noaudio-over-speech", failed(result))

    def test_mic_p50_under_twice_the_floor_fails_p6(self) -> None:
        session = self.session()
        session.seg("system", 1000, 4000, "hello from the fixture", "S1").seg("microphone", 2000, 5000, "me")
        session.pcm("microphone", [(2000, 8000, 0.03)], 12000)
        session.pcm("system", [(1000, 4000, 0.2)], 12000)
        result = run("P6", session.write())
        self.assertEqual(failed(result), {"mic-speech-clears-floor", "provenance"})
        self.assertIn("p50=0.0300", result["evidence"])

    def test_missing_mic_pcm_fails_p6(self) -> None:
        session = self.session()
        session.seg("system", 1000, 4000, "hello", "S1").seg("microphone", 2000, 5000, "me")
        self.assertIn("mic-speech-clears-floor", failed(run("P6", session.write())))


START_WALL_MS = 1790139600000  # 2026-09-23T05:00:00.000Z, the synthetic header
LIVE = "the quick brown fox jumps over the lazy dog again and again"


def p3_run(root: Path, pf_on: int = 5000, pf_off: int = 20000, **overrides) -> dict:
    return harness_run(root, "P3", pfOnWallMs=START_WALL_MS + pf_on, pfOffWallMs=START_WALL_MS + pf_off, **overrides)


def p3_good(case: TempRoot, *, backlog: int | None = 20000, live_at: int = 50000, end: int = 70000) -> Session:
    """pf 5000-20000. Engine degrade at 10000, gap 10000-26000, resumed at 26000."""
    session = case.session()
    session.seg("system", 1000, 4000, "before the block")
    session.ann(10000, "degraded", "ws closed (1006); reconnect #1 in 1s track=system")
    session.ann(26000, "gap", {"fromMs": 10000, "toMs": 26000, "track": "system"})
    resumed = "transport resumed track=system" + (f" backlogMs={backlog}" if backlog is not None else "")
    session.ann(26000, "resumed", resumed)
    session.seg("system", 26000, 29000, "replayed backlog words")
    session.seg("system", live_at, live_at + 4000, LIVE)
    session.end(end)
    return session


class P3Tests(TempRoot):
    def test_block_resume_and_live_speech_past_backlog_has_all_checks_ok(self) -> None:
        p3_run(self.root)
        assert_checks_ok_but_unproven(self, run("P3", p3_good(self).write()))

    def test_todays_shape_one_backlog_seg_at_resumed_fails(self) -> None:
        # 95837a8: degraded, seg at resumed.atMs, gap, resumed. No track, no
        # backlog, and the only seg after resume is replayed audio.
        p3_run(self.root)
        session = self.session()
        session.ann(10000, "degraded", "ws closed (1006); reconnect #1 in 1s")
        session.seg("system", 26000, 29000, "replayed backlog words")
        session.ann(26000, "gap", {"fromMs": 10000, "toMs": 26000, "track": "system"})
        session.ann(26000, "resumed", "transport resumed")
        session.end(40000)
        result = run("P3", session.write())
        self.assertEqual(result["result"], "fail")
        self.assertIn("system:degrade-in-block", failed(result))
        self.assertIn("system:resumed", failed(result))

    def test_tracked_chain_with_only_backlog_segs_fails_live_seg(self) -> None:
        p3_run(self.root)
        result = run("P3", p3_good(self, live_at=40000).write())
        self.assertEqual(result["result"], "fail")
        self.assertIn("system:live-seg", failed(result))
        self.assertIn("backlog seg(s)", result["evidence"])

    def test_missing_backlog_uses_the_conservative_fallback(self) -> None:
        p3_run(self.root)
        # liveFrom = 26000 + 16000 gap + 30000 + 3000 = 75000.
        self.assertIn("system:live-seg", failed(run("P3", p3_good(self, backlog=None).write())))

    def test_startup_handshake_degrade_plus_unrelated_gap_fails(self) -> None:
        p3_run(self.root)
        session = self.session()
        session.ann(2000, "degraded", "no transcript.created within 5000ms track=system emittedAtMs=2100")
        session.ann(26000, "gap", {"fromMs": 10000, "toMs": 26000, "track": "system"})
        session.ann(26000, "resumed", "transport resumed track=system backlogMs=0")
        session.seg("system", 30000, 34000, LIVE).end(60000)
        result = run("P3", session.write())
        self.assertEqual(result["result"], "fail")
        self.assertIn("system:degrade-in-block", failed(result))

    def test_relapse_after_resume_fails(self) -> None:
        p3_run(self.root)
        session = p3_good(self)
        session.rows.insert(-1, {"t": "ann", "atMs": 60000, "kind": "degraded", "detail": "ws closed (1006); reconnect #1 in 1s track=system"})
        result = run("P3", session.write())
        self.assertEqual(result["result"], "fail")
        self.assertIn("system:no-relapse", failed(result))

    def test_short_tail_fails(self) -> None:
        p3_run(self.root)
        self.assertIn("system:tail", failed(run("P3", p3_good(self, end=55000).write())))

    def test_resume_while_pf_on_is_invalid(self) -> None:
        p3_run(self.root, pf_on=5000, pf_off=40000)
        result = run("P3", p3_good(self).write())
        self.assertEqual(result["result"], "invalid")
        self.assertIn("system:resume-after-unblock", failed(result))

    def test_short_block_is_invalid(self) -> None:
        p3_run(self.root)
        session = p3_good(self)
        session.rows[3]["detail"] = {"fromMs": 20000, "toMs": 26000, "track": "system"}
        result = run("P3", session.write())
        self.assertEqual(result["result"], "invalid")
        self.assertIn("system:gap-span", failed(result))

    def test_missing_pf_window_fails(self) -> None:
        harness_run(self.root, "P3")
        result = run("P3", p3_good(self).write())
        self.assertEqual(result["result"], "fail")
        self.assertIn("pf-window", failed(result))

    def test_microphone_gap_needs_its_own_resumed(self) -> None:
        p3_run(self.root)
        session = p3_good(self)
        session.rows.insert(3, {"t": "ann", "atMs": 25000, "kind": "gap", "detail": {"fromMs": 10500, "toMs": 25000, "track": "microphone"}})
        session.rows.insert(2, {"t": "ann", "atMs": 10500, "kind": "degraded", "detail": "ws closed (1006); reconnect #1 in 1s track=microphone"})
        result = run("P3", session.write())
        self.assertEqual(result["result"], "fail")
        self.assertIn("microphone:resumed", failed(result))
        # The system resumed does not stand in for the microphone.
        session.rows.insert(-1, {"t": "ann", "atMs": 25000, "kind": "resumed", "detail": "transport resumed track=microphone backlogMs=15000"})
        assert_checks_ok_but_unproven(self, run("P3", session.write()))


class P1GapTests(TempRoot):
    def test_dc_offset_system_pcm_is_not_a_false_hole(self) -> None:
        text = REF.read_text()
        session = self.session().seg("system", 0, 3000, text).end(12000)
        session.pcm("system", [(0, 3000, 0.2)], 12000, dc=2000)
        result = run("P1", session.write(), ref=REF)
        self.assertNotIn("gaps", failed(result), result["evidence"])

    def test_uncovered_system_speech_is_a_hole(self) -> None:
        text = REF.read_text()
        session = self.session().seg("system", 0, 3000, text)
        session.pcm("system", [(0, 9000, 0.2)], 12000)
        self.assertIn("gaps", failed(run("P1", session.write(), ref=REF)))


if __name__ == "__main__":
    unittest.main()
