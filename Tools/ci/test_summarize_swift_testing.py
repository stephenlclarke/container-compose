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

"""Unit tests for explicit Swift Testing evidence counts."""

import importlib.util
import unittest
from pathlib import Path


def load_summary_module():
    """Load the CLI-oriented summary module."""
    module_path = Path(__file__).with_name("summarize-swift-testing.py")
    spec = importlib.util.spec_from_file_location("summarize_swift_testing", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


summary = load_summary_module()


class SwiftTestingSummaryTests(unittest.TestCase):
    """Executed and skipped count extraction."""

    def test_authoritative_total_counts_parameterized_cases(self) -> None:
        """The final total covers cases omitted from one-line test events."""
        log = """
✔ Test "ordinary" passed after 0.001 seconds.
✔ Test "parameterized" with 6 test cases passed after 0.001 seconds.
➜ Test "live one" skipped: "requires runtime"
➜ Test "live two" skipped: "requires runtime"
✔ Test run with 9 tests in 2 suites passed after 0.001 seconds.
"""

        self.assertEqual(summary.testing_counts(log), (7, 2))

    def test_event_count_is_fallback_without_final_summary(self) -> None:
        """Interrupted logs retain the observable event count."""
        log = """
✔ Test "one" passed after 0.001 seconds.
✘ Test "two" failed after 0.001 seconds.
➜ Test "live" skipped: "requires runtime"
"""

        self.assertEqual(summary.testing_counts(log), (2, 1))

    def test_rejects_more_skips_than_discovered_tests(self) -> None:
        """Malformed summaries cannot produce a negative executed count."""
        log = """
➜ Test "one" skipped: "requires runtime"
➜ Test "two" skipped: "requires runtime"
✔ Test run with 1 test in 1 suite passed after 0.001 seconds.
"""

        with self.assertRaisesRegex(ValueError, "2 skipped tests from 1 discovered"):
            summary.testing_counts(log)


if __name__ == "__main__":
    unittest.main()
