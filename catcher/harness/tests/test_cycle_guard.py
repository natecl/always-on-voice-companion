"""Tier L. Harness fail-closed guards. Not a Mac P1–P6 result."""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "test_cycle_guard.sh"


class CycleGuardTests(unittest.TestCase):
    def test_preflight_stop_root_and_no_process(self) -> None:
        completed = subprocess.run(["bash", str(SCRIPT)], check=False, text=True, capture_output=True)
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
