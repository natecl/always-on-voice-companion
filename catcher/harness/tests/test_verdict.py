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


if __name__ == "__main__":
    unittest.main()
