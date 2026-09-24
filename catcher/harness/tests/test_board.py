"""Board composition and the orphan sweep. Tier L, not a gate result."""

from __future__ import annotations

import hashlib
import json
import signal
import sys
import unittest
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS))
import board  # noqa: E402


class OrphanTests(unittest.TestCase):
    def test_kind_matches_catcher_and_the_fixture_only(self) -> None:
        self.assertEqual(board.orphan_kind("/tmp/Catcher.app/Contents/MacOS/CatcherApp --harness"), "catcher")
        self.assertEqual(board.orphan_kind("afplay catcher/harness/fixtures/known-60s.wav"), "afplay")
        self.assertIsNone(board.orphan_kind("afplay /tmp/other.wav"))
        self.assertIsNone(board.orphan_kind("python3 board.py"))

    def test_reap_matches_the_real_bundle_and_a_truncated_ps_line(self) -> None:
        """LaunchServices runs CatcherApp.app even when the harness opened Catcher.app.

        A wide `ps` line includes Contents/MacOS/CatcherApp. A truncated line
        can stop at the bundle name. Both are the same orphan.
        """
        session = "/tmp/catcher-auto/run/preflight"
        symlink = f"/build/Debug/Catcher.app/Contents/MacOS/CatcherApp --preflight --session-root {session}"
        real = f"/build/Debug/CatcherApp.app/Contents/MacOS/CatcherApp --preflight --session-root {session}"
        truncated = "/Users/n/Debug/CatcherApp.app"
        self.assertEqual(board.orphan_kind(symlink), "catcher")
        self.assertEqual(board.orphan_kind(real), "catcher")
        self.assertEqual(board.orphan_kind(truncated), "catcher")
        self.assertTrue(board.is_preflight_process(symlink, session))
        self.assertTrue(board.is_preflight_process(real, session))
        self.assertFalse(board.is_preflight_process(real, "/tmp/other-session/preflight"))
        self.assertFalse(board.is_preflight_process(truncated, session))
        self.assertFalse(board.is_preflight_process(
            f"/build/Debug/CatcherApp.app/Contents/MacOS/CatcherApp --session-root {session}",
            session,
        ))
        self.assertIsNone(board.orphan_kind("/tmp/NotCatcher.app/Contents/MacOS/Other"))

    def test_reap_kills_and_records_a_clear_sweep(self) -> None:
        root = Path(self.id().replace(".", "_"))
        # Use a real temp dir via unittest's default tmp is not available; make one.
        import tempfile
        tmp = Path(tempfile.mkdtemp())
        obs = tmp / "obs" / "orphans.jsonl"
        seen = {"n": 0}

        def lister():
            seen["n"] += 1
            if seen["n"] == 1:
                return [(9, "/Apps/Catcher.app/Contents/MacOS/CatcherApp")]
            return []

        killed = []
        clock = {"t": 0.0}

        def killer(pid, sig):
            self.assertEqual(sig, signal.SIGKILL)
            killed.append(pid)

        status = board.reap_orphans(
            obs, lister=lister, killer=killer, pause=lambda _s: None, now=lambda: clock.__setitem__("t", clock["t"] + 1) or clock["t"],
        )
        self.assertEqual(status, 0)
        self.assertEqual(killed, [9])
        record = json.loads(obs.read_text(encoding="utf-8").splitlines()[0])
        self.assertEqual(record["tag"], "ok")
        self.assertEqual(record["survivors"], [])

    def test_reap_fail_closed_when_a_process_survives(self) -> None:
        import tempfile
        tmp = Path(tempfile.mkdtemp())
        obs = tmp / "orphans.jsonl"
        clock = {"t": 0.0}

        def now():
            clock["t"] += 0.3
            return clock["t"]

        status = board.reap_orphans(
            obs,
            lister=lambda: [(4, "afplay /x/known-60s.wav")],
            killer=lambda pid, sig: None,
            pause=lambda _s: None,
            now=now,
        )
        self.assertEqual(status, 1)
        record = json.loads(obs.read_text(encoding="utf-8").splitlines()[0])
        self.assertEqual(record["tag"], "orphan-survived")
        self.assertEqual(record["survivors"][0]["pid"], 4)


def _preflight(run: Path, line: str) -> None:
    path = run / "preflight"
    path.mkdir(parents=True)
    (path / "preflight.txt").write_text(line + "\n", encoding="utf-8")


class ComposeTests(unittest.TestCase):
    def setUp(self) -> None:
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.run = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_red_preflight_launches_nothing(self) -> None:
        _preflight(self.run, "PREFLIGHT RESULT FAIL failed=1 source=harness")
        (self.run / "obs").mkdir()
        (self.run / "obs" / "orphans.jsonl").write_text(
            json.dumps({"killed": [], "survivors": [], "tag": "ok"}) + "\n", encoding="utf-8"
        )
        (self.run / "obs" / "board-env.json").write_text(json.dumps({
            "harnessGitSHA": "abc",
            "cdhash": "57250034b55e54e3ad6798983edf6e62c1553653",
            "catcherGitSHA": "b14e31a99a431e5cac6a49669f5c1955de38a1d1",
            "greenEligible": True,
        }), encoding="utf-8")
        built = board.compose(self.run, stopped="preflight", expect_sha="b14e31a99a431e5cac6a49669f5c1955de38a1d1", expect_cdhash="57250034")
        self.assertEqual(built["verdict"]["value"], "RED")
        self.assertEqual(built["gatesLaunched"]["value"], 0)
        self.assertEqual(built["afplayLaunched"]["value"], "not-observed")
        self.assertIn("PREFLIGHT RESULT FAIL", built["preflightLines"]["value"][0])
        self.assertFalse((self.run / "p1").exists())
        text = (self.run / "board.md").read_text(encoding="utf-8")
        self.assertIn("PREFLIGHT RESULT FAIL", text)
        self.assertIn("not-observed", text)

    def test_missing_obs_is_not_a_pass(self) -> None:
        _preflight(self.run, "PREFLIGHT RESULT PASS")
        (self.run / "obs").mkdir()
        (self.run / "obs" / "orphans.jsonl").write_text(
            json.dumps({"killed": [], "survivors": [], "tag": "ok"}) + "\n", encoding="utf-8"
        )
        (self.run / "p1").mkdir()
        built = board.compose(self.run)
        self.assertEqual(built["gates"]["P1"]["tag"]["value"], "not-observed")
        self.assertNotEqual(built["gates"]["P1"]["pass"]["value"], True)
        self.assertEqual(built["verdict"]["value"], "RED")

    def test_wrong_build_is_not_red_or_green(self) -> None:
        _preflight(self.run, "PREFLIGHT RESULT PASS")
        (self.run / "obs").mkdir()
        (self.run / "obs" / "board-env.json").write_text(json.dumps({
            "harnessGitSHA": "abc", "cdhash": "deadbeef", "catcherGitSHA": "fff999", "greenEligible": True,
        }), encoding="utf-8")
        (self.run / "obs" / "orphans.jsonl").write_text(
            json.dumps({"killed": [], "survivors": [], "tag": "ok"}) + "\n", encoding="utf-8"
        )
        built = board.compose(
            self.run,
            expect_sha="b14e31a99a431e5cac6a49669f5c1955de38a1d1",
            expect_cdhash="57250034b55e54e3ad6798983edf6e62c1553653",
        )
        self.assertEqual(built["verdict"]["value"], "invalid (wrong build)")

    def test_log_stamp_changes_when_the_file_is_truncated(self) -> None:
        log = self.run / "p1"
        log.mkdir()
        target = log / "gate.log"
        target.write_text("full output\n", encoding="utf-8")
        _preflight(self.run, "PREFLIGHT RESULT FAIL")
        first = board.compose(self.run, stopped="preflight")
        digest = first["logs"]["p1/gate.log"]["sha256"]
        self.assertEqual(digest, hashlib.sha256(b"full output\n").hexdigest())
        target.write_text("full\n", encoding="utf-8")
        second = board.compose(self.run, stopped="preflight")
        self.assertNotEqual(second["logs"]["p1/gate.log"]["sha256"], digest)
        self.assertEqual(second["logs"]["p1/gate.log"]["bytes"], len(b"full\n"))

    def test_exec_gate_timeout_writes_the_tag_and_does_not_read_stdin(self) -> None:
        log = self.run / "gate.log"
        obs = self.run / "rig_obs.json"
        status = board.exec_gate(
            0.3,
            log,
            obs,
            [sys.executable, "-c", "import sys,time; sys.stdin.read(); time.sleep(5)"],
        )
        self.assertEqual(status, 124)
        self.assertEqual(json.loads(obs.read_text(encoding="utf-8"))["tag"], "timeout")
        self.assertTrue(log.is_file())


class ExecTests(unittest.TestCase):
    def test_exec_gate_returns_the_command_status(self) -> None:
        import tempfile
        tmp = Path(tempfile.mkdtemp())
        status = board.exec_gate(2, tmp / "gate.log", tmp / "rig_obs.json", [sys.executable, "-c", "raise SystemExit(3)"])
        self.assertEqual(status, 3)
        self.assertFalse((tmp / "rig_obs.json").exists())

    def test_exec_gate_cli_runs_the_remainder(self) -> None:
        """The subparser dest must not share a name with the remainder.

        `python3 board.py exec-gate ... -- <cmd>` is how board.sh starts
        preflight. A remainder also named `command` overwrote the subparser
        and compose ran instead.
        """
        import tempfile
        tmp = Path(tempfile.mkdtemp())
        log = tmp / "gate.log"
        obs = tmp / "rig_obs.json"
        status = board.main([
            "exec-gate",
            "--timeout", "2",
            "--log", str(log),
            "--obs", str(obs),
            "--",
            sys.executable, "-c", "raise SystemExit(3)",
        ])
        self.assertEqual(status, 3)
        self.assertTrue(log.is_file())
        self.assertFalse(obs.exists())


class CdhashTests(unittest.TestCase):
    def test_verbose_4_is_required_to_ask_for_cdhash(self) -> None:
        args = board.codesign_cdhash_args("/tmp/Catcher.app")
        self.assertEqual(args[:3], ["codesign", "-d", "--verbose=4"])
        self.assertEqual(args[-1], "/tmp/Catcher.app")

    def test_cdhash_line_is_parsed_and_a_display_without_it_stays_blank(self) -> None:
        shown = (
            "Executable=/tmp/Catcher.app/Contents/MacOS/CatcherApp\n"
            "Identifier=com.catcher.app\n"
            "CandidateCDHash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
            "CDHash=57250034b55e54e3ad6798983edf6e62c1553653\n"
        )
        self.assertEqual(
            board.cdhash_from_codesign(shown),
            "57250034b55e54e3ad6798983edf6e62c1553653",
        )
        hidden = "Identifier=com.catcher.app\nSignature size=4789\nTeamIdentifier=not set\n"
        self.assertEqual(board.cdhash_from_codesign(hidden), "")

    def test_preflight_stamp_reuses_the_verbose_4_parser(self) -> None:
        script = (HARNESS / "preflight.sh").read_text(encoding="utf-8")
        self.assertIn("board.codesign_cdhash_args", script)
        self.assertIn("board.cdhash_from_codesign", script)
        self.assertNotRegex(script, r"codesign\s+-d")
        self.assertIn('kill_preflight_app "$SESSION"', script)
        self.assertNotIn('kill_preflight_app "$APP"', script)


NO_RESULT = (
    "PREFLIGHT signing PASS source=harness\n"
    "PREFLIGHT preflight-finish FAIL error=no-result source=harness\n"
    "PREFLIGHT RESULT FAIL failed=1 source=harness\n"
)
APP_PASS = (
    "PREFLIGHT signing PASS source=harness\n"
    "PREFLIGHT tcc-screen PASS\n"
    "PREFLIGHT capture-probe PASS system=48000 microphone=48000\n"
    "PREFLIGHT RESULT PASS failed=0\n"
)
APP_FAIL = (
    "PREFLIGHT signing PASS source=harness\n"
    "PREFLIGHT api-stt FAIL error=timeout\n"
    "PREFLIGHT RESULT FAIL failed=1\n"
)


class PreflightRetryTests(unittest.TestCase):
    def setUp(self) -> None:
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.session = str(Path(self.tmp.name) / "preflight")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _attempts(self, *reports: str):
        calls = {"n": 0}

        def attempt() -> None:
            text = reports[calls["n"]]
            calls["n"] += 1
            Path(self.session, "preflight.txt").write_text(text, encoding="utf-8")

        return attempt, calls

    def _run(self, attempt, lister=lambda: []) -> int:
        clock = {"t": 0.0}

        def now() -> float:
            clock["t"] += 1.0
            return clock["t"]

        return board.run_preflight(
            self.session, attempt, lister=lister, killer=lambda pid, sig: None, pause=lambda _s: None, now=now,
        )

    def _record(self) -> dict:
        return json.loads(Path(self.session, "preflight_attempts.json").read_text(encoding="utf-8"))

    def test_result_wait_is_120s_and_the_docs_quote_it(self) -> None:
        limits = json.loads((HARNESS / "thresholds.json").read_text(encoding="utf-8"))
        wait = limits["rigPreflightTimeoutS"]
        self.assertEqual(wait, 120)
        script = (HARNESS / "preflight.sh").read_text(encoding="utf-8")
        self.assertIn('["rigPreflightTimeoutS"]', script)
        docs = HARNESS.parents[1] / "docs" / "qa"
        for name in ("v0-diagnostics.md", "v0-grading.md", "rig-self-test.md"):
            text = (docs / name).read_text(encoding="utf-8")
            self.assertIn(f"{wait}s", text, name)
            self.assertNotIn("40s", text, name)

    def test_board_preflight_budget_holds_both_attempts(self) -> None:
        limits = json.loads((HARNESS / "thresholds.json").read_text(encoding="utf-8"))
        outer = limits["rigGateTimeoutS"]["preflight"]
        self.assertEqual(board.PREFLIGHT_ATTEMPTS, 2)
        self.assertGreaterEqual(outer, board.PREFLIGHT_ATTEMPTS * limits["rigPreflightTimeoutS"] + 30)
        self.assertIn(f"{outer}s", (HARNESS.parents[1] / "docs" / "qa" / "v0-diagnostics.md").read_text(encoding="utf-8"))

    def test_no_result_is_retried_once_then_passes(self) -> None:
        attempt, calls = self._attempts(NO_RESULT, APP_PASS)
        self.assertEqual(self._run(attempt), 0)
        self.assertEqual(calls["n"], 2)
        self.assertEqual(Path(self.session, "preflight.txt").read_text(encoding="utf-8"), APP_PASS)
        self.assertEqual(Path(self.session, "preflight.attempt1.txt").read_text(encoding="utf-8"), NO_RESULT)
        record = self._record()
        self.assertEqual([row["noResult"] for row in record["attempts"]], [True, False])
        self.assertEqual(record["attempts"][1]["result"], "PREFLIGHT RESULT PASS failed=0")

    def test_two_no_results_fail_without_a_third_attempt(self) -> None:
        attempt, calls = self._attempts(NO_RESULT, NO_RESULT, APP_PASS)
        self.assertEqual(self._run(attempt), 1)
        self.assertEqual(calls["n"], 2)
        last = Path(self.session, "preflight.txt").read_text(encoding="utf-8").splitlines()[-1]
        self.assertEqual(last, "PREFLIGHT RESULT FAIL failed=1 source=harness")
        self.assertEqual([row["noResult"] for row in self._record()["attempts"]], [True, True])

    def test_an_app_fail_is_not_retried(self) -> None:
        attempt, calls = self._attempts(APP_FAIL, APP_PASS)
        self.assertEqual(self._run(attempt), 1)
        self.assertEqual(calls["n"], 1)
        self.assertFalse(Path(self.session, "preflight.attempt1.txt").exists())

    def test_a_surviving_preflight_blocks_the_retry(self) -> None:
        attempt, calls = self._attempts(NO_RESULT, APP_PASS)
        stuck = [(41, f"/b/CatcherApp.app/Contents/MacOS/CatcherApp --preflight --session-root {self.session}")]
        self.assertEqual(self._run(attempt, lister=lambda: stuck), 1)
        self.assertEqual(calls["n"], 1)
        report = Path(self.session, "preflight.txt").read_text(encoding="utf-8")
        self.assertIn("error=preflight-survived source=harness", report)
        self.assertEqual(self._record()["attempts"][0]["survivors"][0]["pid"], 41)

    def test_preflight_cli_retries_the_single_attempt_command(self) -> None:
        script = Path(self.tmp.name) / "once.py"
        script.write_text(
            "import sys\n"
            "from pathlib import Path\n"
            "session = Path(sys.argv[1])\n"
            "count = session / 'count'\n"
            "n = int(count.read_text()) + 1 if count.exists() else 1\n"
            "count.write_text(str(n))\n"
            f"text = {NO_RESULT!r} if n == 1 else {APP_PASS!r}\n"
            "(session / 'preflight.txt').write_text(text)\n",
            encoding="utf-8",
        )
        Path(self.session).mkdir(parents=True)
        status = board.main(["preflight", "--session", self.session, "--", sys.executable, str(script), self.session])
        self.assertEqual(status, 0)
        self.assertEqual(Path(self.session, "count").read_text(), "2")

    def test_board_quotes_the_attempts(self) -> None:
        run = Path(self.tmp.name) / "run"
        self.session = str(run / "preflight")
        attempt, _calls = self._attempts(NO_RESULT, NO_RESULT)
        self._run(attempt)
        built = board.compose(run, stopped="preflight")
        self.assertEqual(built["verdict"]["value"], "RED")
        self.assertEqual(len(built["preflightAttempts"]["value"]["attempts"]), 2)
        self.assertNotEqual(built["logs"]["preflight/preflight.attempt1.txt"]["bytes"], "not-observed")
        self.assertIn("preflight attempts:", (run / "board.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
