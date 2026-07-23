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

"""Tests for Current Homebrew formula version generation."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("current-formula-version.py")
SPEC = importlib.util.spec_from_file_location("current_formula_version", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CurrentFormulaVersionTests(unittest.TestCase):
    def test_run_number_precedes_commit_identity(self) -> None:
        self.assertEqual(
            MODULE.current_formula_version(
                "846",
                "0e7d6e7386a068fb44f62d306127613814404aa5",
            ),
            "current.846.0e7d6e7386a0",
        )

    def test_leading_zeroes_do_not_create_distinct_versions(self) -> None:
        self.assertEqual(
            MODULE.current_formula_version(
                "000846",
                "0e7d6e7386a068fb44f62d306127613814404aa5",
            ),
            "current.846.0e7d6e7386a0",
        )

    def test_rejects_invalid_run_numbers(self) -> None:
        for run_number in ("", "0", "-1", "current", "1.5"):
            with self.subTest(run_number=run_number):
                with self.assertRaisesRegex(ValueError, "positive decimal integer"):
                    MODULE.current_formula_version(
                        run_number,
                        "0e7d6e7386a068fb44f62d306127613814404aa5",
                    )

    def test_rejects_noncanonical_commits(self) -> None:
        for commit in (
            "",
            "0e7d6e7386a0",
            "0E7D6E7386A068FB44F62D306127613814404AA5",
            "ge7d6e7386a068fb44f62d306127613814404aa5",
        ):
            with self.subTest(commit=commit):
                with self.assertRaisesRegex(ValueError, "lowercase 40-character"):
                    MODULE.current_formula_version("846", commit)

    def test_cli_prints_version(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--run-number",
                "847",
                "--commit",
                "ffffffffffffffffffffffffffffffffffffffff",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.stdout, "current.847.ffffffffffff\n")

    def test_cli_rejects_invalid_input(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--run-number",
                "0",
                "--commit",
                "ffffffffffffffffffffffffffffffffffffffff",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("positive decimal integer", result.stderr)


if __name__ == "__main__":
    unittest.main()
