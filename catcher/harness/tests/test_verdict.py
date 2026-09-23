"""verdict.py aggregation. Tier L: regression only."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import verdict  # noqa: E402
from test_grade import TempRoot, harness_run, p6_session  # noqa: E402


def entry(result: str = "pass", sha: str = "abc123", cdhash: str = "deadbeef") -> dict:
    return {"result": result, "sha": sha, "cdhash": cdhash}


class DecideTests(unittest.TestCase):
    def test_six_passes_on_one_build_is_green(self) -> None:
        status, reasons, sha, cdhash = verdict.decide({name: entry() for name in verdict.grade.GATES})
        self.assertEqual((status, reasons, sha, cdhash), ("GREEN", [], "abc123", "deadbeef"))

    def test_unproven_or_invalid_gate_is_red(self) -> None:
        for result in ("unproven", "invalid", "fail", "n/a"):
            with self.subTest(result=result):
                gates = {name: entry() for name in verdict.grade.GATES}
                gates["P4"] = entry(result)
                status, reasons, _, _ = verdict.decide(gates)
                self.assertEqual(status, "RED")
                self.assertIn(f"P4 {result}", reasons)

    def test_mixed_sha_is_red_even_when_every_gate_passes(self) -> None:
        gates = {name: entry() for name in verdict.grade.GATES}
        gates["P3"] = entry(sha="fff999")
        status, reasons, sha, _ = verdict.decide(gates)
        self.assertEqual(status, "RED")
        self.assertEqual(sha, "")
        self.assertTrue(any("CatcherGitSHA" in reason for reason in reasons))

    def test_mixed_or_missing_cdhash_is_red(self) -> None:
        for bad in ("cafe", ""):
            with self.subTest(cdhash=bad):
                gates = {name: entry() for name in verdict.grade.GATES}
                gates["P2"] = entry(cdhash=bad)
                self.assertEqual(verdict.decide(gates)[0], "RED")

    def test_missing_gate_is_red(self) -> None:
        gates = {name: entry() for name in verdict.grade.GATES if name != "P6"}
        self.assertIn("P6 missing", verdict.decide(gates)[1])


class VerdictCliTests(TempRoot):
    def roots(self, **p6_kwargs) -> dict[str, Path]:
        made: dict[str, Path] = {}
        for name in verdict.grade.GATES:
            root = self.root / name.lower()
            root.mkdir()
            harness_run(root, name)
            case = TempRoot()
            case.root = root
            p6_session(case, **(p6_kwargs if name == "P1" else {}))
            made[name] = root
        return made

    def cli(self, roots: dict[str, Path]) -> tuple[int, dict]:
        args = [sys.executable, str(HARNESS / "verdict.py"), "--out", str(self.root / "out")]
        for name, root in roots.items():
            args += [f"--{name.lower()}", str(root)]
        status = subprocess.run(args, capture_output=True, check=False).returncode
        return status, json.loads((self.root / "out" / "v0-verdict.json").read_text())

    def test_stub_p1_is_red(self) -> None:
        status, report = self.cli(self.roots(engine="stub"))
        self.assertEqual(status, 1)
        self.assertEqual(report["verdict"], "RED")
        self.assertEqual(report["gates"]["P1"]["result"], "fail")

    def test_linux_regrade_is_never_green(self) -> None:
        status, report = self.cli(self.roots())
        self.assertEqual(status, 1)
        self.assertEqual(report["verdict"], "RED")
        self.assertTrue(report["gradedOn"])


class GreenEndToEndTests(TempRoot):
    """Six genuine-shaped sessions graded as if on a Mac. Proves GREEN is
    reachable and that one bad ingredient turns it RED."""

    def setUp(self) -> None:
        super().setUp()
        self._host = verdict.grade.platform_system
        verdict.grade.platform_system = lambda: "Darwin"

    def tearDown(self) -> None:
        verdict.grade.platform_system = self._host
        super().tearDown()

    def case(self, name: str) -> TempRoot:
        root = self.root / name.lower()
        root.mkdir()
        case = TempRoot()
        case.root = root
        return case

    def build(self, p3_sha: str = "abc123") -> dict[str, Path]:
        from test_grade import REF, START_WALL_MS, p3_good, p3_run, p4_session

        roots: dict[str, Path] = {}
        p1 = self.case("P1")
        harness_run(p1.root, "P1")
        session = p1.session().seg("system", 0, 60000, REF.read_text(), "S1")
        session.ann(62000, "recovered").rows.append({"t": "end", "atMs": 62000, "clean": False, "recovered": True})
        p1_dir = session.write()
        roots["P1"] = p1.root
        p2 = self.case("P2")
        harness_run(p2.root, "P2", revokeWallMs=START_WALL_MS + 2500)
        p2.session().seg("system", 0, 2000, "live").ann(3000, "blocked", "screen recording access denied").end(3100, clean=False).write()
        roots["P2"] = p2.root
        p3 = self.case("P3")
        p3_run(p3.root, catcherGitSHA=p3_sha)
        p3_good(p3).write()
        if p3_sha != "abc123":
            events = next(p3.root.glob("*/events.jsonl"))
            events.write_text(events.read_text().replace("0.0.1+abc123", f"0.0.1+{p3_sha}"))
        roots["P3"] = p3.root
        p4 = self.case("P4")
        harness_run(p4.root, "P4", catcherEngine="")
        p4_session(p4).end(16000).write()
        roots["P4"] = p4.root
        p5 = self.case("P5")
        harness_run(p5.root, "P5", catcherEngine="stub")
        stub = p5.session(engine="stub")
        stub.rows = [dict(row) for row in json.loads("[" + ",".join((p1_dir / "events.jsonl").read_text().splitlines()) + "]")]
        stub.rows[0]["engine"] = "stub"
        stub.write()
        roots["P5"] = p5.root
        p6 = self.case("P6")
        harness_run(p6.root, "P6")
        p6_session(p6)
        roots["P6"] = p6.root
        return roots

    def verdict(self, roots: dict[str, Path]) -> dict:
        argv = sys.argv
        sys.argv = ["verdict.py", "--out", str(self.root / "out")]
        for name, root in roots.items():
            sys.argv += [f"--{name.lower()}", str(root)]
        try:
            verdict.main()
        finally:
            sys.argv = argv
        return json.loads((self.root / "out" / "v0-verdict.json").read_text())

    def test_six_passes_on_one_build_are_green(self) -> None:
        report = self.verdict(self.build())
        self.assertEqual(report["verdict"], "GREEN", json.dumps(report["reasons"]) + json.dumps({k: v["evidence"] for k, v in report["gates"].items() if v["result"] != "pass"}))
        self.assertEqual(report["sha"], "abc123")
        self.assertEqual(report["cdhash"], "deadbeef")

    def test_one_gate_from_another_build_is_red(self) -> None:
        report = self.verdict(self.build(p3_sha="fff999"))
        self.assertEqual(report["verdict"], "RED")
        self.assertEqual(report["gates"]["P3"]["result"], "pass")
        self.assertTrue(any("CatcherGitSHA" in reason for reason in report["reasons"]))


if __name__ == "__main__":
    unittest.main()
