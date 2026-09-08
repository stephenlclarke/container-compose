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

from __future__ import annotations

import argparse
from collections.abc import Callable, Sequence
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).with_name("benchmark-authority.py")
SPEC = importlib.util.spec_from_file_location("benchmark_authority", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
AUTHORITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTHORITY)


class BenchmarkAuthorityTests(unittest.TestCase):
    controls_ref = "a" * 40
    release_ref = "b" * 40

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary_directory.name)
        subprocess.run(["git", "init", "-q", self.repository], check=True)
        subprocess.run(
            ["git", "config", "user.name", "Tests"], cwd=self.repository, check=True
        )
        subprocess.run(
            ["git", "config", "user.email", "tests@example.com"],
            cwd=self.repository,
            check=True,
        )
        (self.repository / "controls.txt").write_text("exact\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=self.repository, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", "test: add controls"],
            cwd=self.repository,
            check=True,
        )
        self.controls_ref = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=self.repository,
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.strip()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def options(self, *extra: str) -> argparse.Namespace:
        return AUTHORITY.parse_arguments(
            (
                "--source",
                str(self.repository),
                "--controls-ref",
                self.controls_ref,
                "--release",
                f"owner/compose|1.2.3|12|{self.release_ref}",
                *extra,
            )
        )

    def remote_result(
        self,
        original: Callable[[Sequence[str], Path | None], str],
        arguments: Sequence[str],
        cwd: Path | None = None,
    ) -> str:
        if cwd is not None:
            return original(arguments, cwd)
        joined = " ".join(arguments)
        if "releases/tags/1.2.3" in joined:
            return (
                '{"id":12,"tag_name":"1.2.3",'
                '"draft":false,"prerelease":false}'
            )
        if "--tags" in arguments:
            return f"{self.release_ref}\trefs/tags/1.2.3"
        raise AssertionError(arguments)

    def test_allowed_report_output_preserves_a_stable_authority(self) -> None:
        report = self.repository / "docs" / "benchmarks" / "report.md"
        report.parent.mkdir(parents=True)
        report.write_text("evidence\n", encoding="utf-8")
        original = AUTHORITY.run_command

        with mock.patch.object(
            AUTHORITY,
            "run_command",
            side_effect=lambda arguments, cwd=None: self.remote_result(
                original, arguments, cwd
            ),
        ):
            first = AUTHORITY.authority_digest(
                self.options("--allow-output", "docs/benchmarks/report.md")
            )
            second = AUTHORITY.authority_digest(
                self.options("--allow-output", "docs/benchmarks/report.md")
            )

        self.assertRegex(first, r"^[0-9a-f]{64}$")
        self.assertEqual(first, second)

    def test_changed_controls_are_rejected(self) -> None:
        (self.repository / "controls.txt").write_text("changed\n", encoding="utf-8")
        original = AUTHORITY.run_command

        with mock.patch.object(
            AUTHORITY,
            "run_command",
            side_effect=lambda arguments, cwd=None: self.remote_result(
                original, arguments, cwd
            ),
        ):
            with self.assertRaisesRegex(ValueError, "controls changed"):
                AUTHORITY.authority_digest(self.options())

    def test_moved_release_tag_is_rejected(self) -> None:
        original = AUTHORITY.run_command

        def changed(arguments: Sequence[str], cwd: Path | None = None) -> str:
            result = self.remote_result(original, arguments, cwd)
            if cwd is None and "--tags" in arguments:
                return result.replace(self.release_ref, "d" * 40)
            return result

        with mock.patch.object(AUTHORITY, "run_command", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "release tag moved"):
                AUTHORITY.authority_digest(self.options())


if __name__ == "__main__":
    unittest.main()
