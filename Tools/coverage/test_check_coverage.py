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

"""Unit tests for the local coverage threshold checker."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


def load_check_coverage_module():
    """Load check-coverage.py despite its CLI-oriented filename."""
    module_path = Path(__file__).with_name("check-coverage.py")
    spec = importlib.util.spec_from_file_location("check_coverage", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check_coverage = load_check_coverage_module()


class CoverageCheckTests(unittest.TestCase):
    """Coverage checker behavior that guards the repository quality gate."""

    def test_empty_generic_coverage_is_uncovered(self) -> None:
        """An empty Swift/Sonar coverage XML report must not pass as 100%."""
        with tempfile.TemporaryDirectory() as directory:
            coverage_path = Path(directory) / "coverage.xml"
            coverage_path.write_text('<coverage version="1"></coverage>', encoding="utf-8")

            self.assertEqual(check_coverage.generic_line_coverage(coverage_path), 0.0)

    def test_empty_go_profile_is_uncovered(self) -> None:
        """A Go coverage profile with no statements must not pass as 100%."""
        with tempfile.TemporaryDirectory() as directory:
            coverage_path = Path(directory) / "coverage.out"
            coverage_path.write_text("mode: atomic\n", encoding="utf-8")

            self.assertEqual(check_coverage.go_statement_coverage(coverage_path), 0.0)

    def test_non_empty_reports_count_covered_lines_and_statements(self) -> None:
        """Swift line and Go statement coverage still use normal percentages."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swift_coverage = root / "coverage.xml"
            swift_coverage.write_text(
                """
                <coverage version="1">
                  <file path="Sources/Example.swift">
                    <lineToCover lineNumber="1" covered="true" />
                    <lineToCover lineNumber="2" covered="false" />
                  </file>
                </coverage>
                """,
                encoding="utf-8",
            )
            go_coverage = root / "coverage.out"
            go_coverage.write_text(
                """
                mode: atomic
                main.go:1.1,2.1 2 1
                main.go:3.1,4.1 2 0
                """,
                encoding="utf-8",
            )

            self.assertEqual(check_coverage.generic_line_coverage(swift_coverage), 50.0)
            self.assertEqual(check_coverage.go_statement_coverage(go_coverage), 50.0)

    def test_duplicate_go_blocks_are_coalesced_across_test_binaries(self) -> None:
        """Cross-package profiles count each instrumented source region once."""
        with tempfile.TemporaryDirectory() as directory:
            coverage_path = Path(directory) / "coverage.out"
            coverage_path.write_text(
                """
                mode: atomic
                main.go:1.1,2.1 2 0
                main.go:3.1,4.1 2 0
                main.go:1.1,2.1 2 3
                main.go:3.1,4.1 2 0
                """,
                encoding="utf-8",
            )

            self.assertEqual(check_coverage.go_statement_coverage(coverage_path), 50.0)


if __name__ == "__main__":
    unittest.main()
