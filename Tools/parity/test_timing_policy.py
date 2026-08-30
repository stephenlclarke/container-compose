from __future__ import annotations

import math
import pathlib
import unittest

from Tools.parity.timing_policy import (
    exceeds_slowdown_boundary,
    slowdown_ratio,
)


ROOT = pathlib.Path(__file__).resolve().parents[2]


class TimingPolicyTests(unittest.TestCase):
    def test_ratio_below_boundary_passes(self) -> None:
        self.assertFalse(exceeds_slowdown_boundary(1.0, 9.999, 10.0))

    def test_ratio_at_boundary_fails(self) -> None:
        self.assertTrue(exceeds_slowdown_boundary(0.075, 0.75, 10.0))

    def test_ratio_above_boundary_fails_without_absolute_delta_escape(self) -> None:
        self.assertTrue(exceeds_slowdown_boundary(0.05, 0.51, 10.0))

    def test_zero_reference_is_infinite_and_fails(self) -> None:
        self.assertTrue(math.isinf(slowdown_ratio(0.0, 0.1)))
        self.assertTrue(exceeds_slowdown_boundary(0.0, 0.1, 10.0))

    def test_invalid_inputs_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            slowdown_ratio(-1.0, 1.0)
        with self.assertRaises(ValueError):
            slowdown_ratio(1.0, -1.0)
        with self.assertRaises(ValueError):
            slowdown_ratio(math.nan, 1.0)
        with self.assertRaises(ValueError):
            slowdown_ratio(1.0, math.inf)
        with self.assertRaises(ValueError):
            exceeds_slowdown_boundary(1.0, 1.0, 0.0)
        with self.assertRaises(ValueError):
            exceeds_slowdown_boundary(1.0, 1.0, math.nan)

    def test_all_direct_timing_checks_use_the_shared_inclusive_policy(self) -> None:
        scripts = (
            "check-compose-cp-stdio-archive-streams.sh",
            "check-compose-links.sh",
            "check-compose-network-service-discovery.sh",
        )
        for name in scripts:
            with self.subTest(script=name):
                source = (ROOT / "Tools" / "parity" / name).read_text(
                    encoding="utf-8"
                )
                self.assertIn("exceeds_slowdown_boundary", source)
                self.assertIn(
                    'PARITY_TIMING_MAX_RATIO="${PARITY_TIMING_MAX_RATIO:-10}"',
                    source,
                )
                self.assertNotIn("PARITY_TIMING_MIN_DELTA_SECONDS", source)


if __name__ == "__main__":
    unittest.main()
