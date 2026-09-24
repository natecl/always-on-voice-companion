"""pfctl / lsof text the P3 gate has to read. Tier L, not a gate result."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pf_obs  # noqa: E402

STOCK = """
No ALTQ support in kernel
ALTQ related functions disabled
anchor "com.apple/*" all
"""
EMPTY = """
No ALTQ support in kernel
ALTQ related functions disabled
"""
CATCHER = 'anchor "catcher" all\n'
FOREIGN = "block drop all\n"
INFO_ON = "Status: Enabled for 0 days 00:00:01           Debug: Urgent\n"
INFO_OFF = "Status: Disabled                              Debug: Urgent\n"
ENABLE = "pf enabled\nToken : 44\n"
VSR = """
block drop out quick proto tcp from any to <catcher_xai> port = 443
  [ Evaluations: 10      Packets: 4         Bytes: 200         States: 0     ]
block drop out quick proto udp from any to <catcher_xai> port = 443
  [ Evaluations: 2       Packets: 0         Bytes: 0           States: 0     ]
block drop in quick proto tcp from <catcher_xai> port = 443 to any
  [ Evaluations: 3       Packets: 1         Bytes: 40          States: 0     ]
"""
STATES = """
all tcp 10.0.0.8:50000 -> 1.2.3.4:443       ESTABLISHED:ESTABLISHED
all tcp 10.0.0.8:50001 -> 9.9.9.9:443       ESTABLISHED:ESTABLISHED
"""
LSOF = "p42\nn10.0.0.8:50000->1.2.3.4:443\nn10.0.0.8:1->[2606:4700::1]:443\n"


class RulesetTests(unittest.TestCase):
    def test_classes(self) -> None:
        self.assertEqual(pf_obs.classify_ruleset(STOCK), "com.apple")
        self.assertEqual(pf_obs.classify_ruleset(EMPTY), "empty")
        self.assertEqual(pf_obs.classify_ruleset(CATCHER), "catcher")
        self.assertEqual(pf_obs.classify_ruleset(FOREIGN), "foreign")

    def test_enabled_and_token(self) -> None:
        self.assertTrue(pf_obs.info_enabled(INFO_ON))
        self.assertFalse(pf_obs.info_enabled(INFO_OFF))
        self.assertEqual(pf_obs.enable_token(ENABLE), "44")

    def test_sudo_denied(self) -> None:
        self.assertTrue(pf_obs.sudo_denied("sudo: a password is required\n"))
        self.assertFalse(pf_obs.sudo_denied("pf enabled\n"))


class PeerTests(unittest.TestCase):
    def test_lsof_and_dig(self) -> None:
        peers = pf_obs.lsof_peers(LSOF)
        self.assertEqual(peers, [("10.0.0.8", "1.2.3.4"), ("10.0.0.8", "2606:4700::1")])
        self.assertEqual(pf_obs.dig_addresses("api.x.ai.\n1.2.3.4\n::ffff:8.8.8.8\n"), ["1.2.3.4", "8.8.8.8"])

    def test_states_left_ignore_other_peers(self) -> None:
        left = pf_obs.states_for_peers(STATES, ["1.2.3.4"])
        self.assertEqual(len(left), 1)
        self.assertIn("1.2.3.4", left[0])
        self.assertEqual(pf_obs.states_for_peers(STATES, ["8.8.8.8"]), [])

    def test_kills_and_counters_sum_every_block(self) -> None:
        self.assertEqual(pf_obs.killed_states("killed 0 states\nkilled 3 states\n"), 3)
        self.assertEqual(pf_obs.rule_counters(VSR), (4, 1))

    def test_blocks_and_table(self) -> None:
        self.assertTrue(pf_obs.blocks_present(VSR))
        self.assertFalse(pf_obs.blocks_present("pass out all\n"))
        self.assertTrue(pf_obs.table_covers("   1.2.3.4\n   2606:4700::1\n", ["1.2.3.4"]))
        self.assertFalse(pf_obs.table_covers("1.2.3.4\n", ["9.9.9.9"]))


if __name__ == "__main__":
    unittest.main()
