#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MakefileFailFastTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.makefile = (ROOT / "Makefile").read_text(encoding="utf-8")

    def prerequisites(self, target: str) -> list[str]:
        match = re.search(
            rf"^{re.escape(target)}:\s*(.*)$",
            self.makefile,
            flags=re.MULTILINE,
        )
        self.assertIsNotNone(match, f"missing Make target: {target}")
        return match.group(1).split()

    def test_source_governance_precedes_slow_lint_harnesses(self) -> None:
        self.assertEqual(self.prerequisites("check"), ["source-preflight", "lint"])

    def test_source_preflight_orders_cheapest_authorities_first(self) -> None:
        self.assertEqual(
            self.prerequisites("source-preflight"),
            [
                "upstream-handoff-registry-check",
                "stack-consistency",
                "core-runtime-neutrality",
                "check-licenses",
            ],
        )

    def test_static_lint_precedes_test_harnesses(self) -> None:
        prerequisites = self.prerequisites("lint")
        self.assertEqual(prerequisites[0], "lint-static")
        self.assertEqual(
            prerequisites[1:],
            [
                "coverage-tools-test",
                "performance-matrix-harness-test",
                "isolation-performance-harness-test",
                "signal-log-reliability-harness-test",
                "compose-events-harness-test",
            ],
        )


if __name__ == "__main__":
    unittest.main()
