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

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path


SCRIPT = Path(__file__).with_name("conventional-version.py")
SPEC = importlib.util.spec_from_file_location("conventional_version", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
CONVENTIONAL_VERSION = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CONVENTIONAL_VERSION
SPEC.loader.exec_module(CONVENTIONAL_VERSION)


class ConventionalVersionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary_directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.commit("chore: create repository")
        self.git("tag", "1.2.3")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["/usr/bin/git", "-C", str(self.repository), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.strip()

    def commit(self, subject: str, body: str = "") -> None:
        marker = self.repository / "history.txt"
        with marker.open("a", encoding="utf-8") as stream:
            stream.write(f"{subject}\n")
        self.git("add", "history.txt")
        command = ["commit", "-q", "-m", subject]
        if body:
            command.extend(("-m", body))
        self.git(*command)

    def test_fix_selects_patch(self) -> None:
        self.commit("fix(runtime): preserve socket ownership")

        self.assertEqual(
            CONVENTIONAL_VERSION.plan(self.repository),
            {
                "base": "1.2.3",
                "commits": 1,
                "level": "patch",
                "next": "1.2.4",
                "schema": 1,
                "selector": "--+",
            },
        )

    def test_feature_selects_minor_over_patch(self) -> None:
        self.commit("fix: correct retry")
        self.commit("feat(compose): support profiles")

        result = CONVENTIONAL_VERSION.plan(self.repository)

        self.assertEqual(result["level"], "minor")
        self.assertEqual(result["next"], "1.3.0")
        self.assertEqual(result["selector"], "-+-")

    def test_breaking_marker_selects_major(self) -> None:
        self.commit("feat(api)!: replace request schema")

        result = CONVENTIONAL_VERSION.plan(self.repository)

        self.assertEqual(result["level"], "major")
        self.assertEqual(result["next"], "2.0.0")

    def test_breaking_footer_selects_major(self) -> None:
        self.commit(
            "fix(api): accept stable identifiers",
            "BREAKING CHANGE: remove the legacy identifier.",
        )

        self.assertEqual(CONVENTIONAL_VERSION.plan(self.repository)["level"], "major")

    def test_non_release_types_do_not_bump(self) -> None:
        self.commit("docs: explain build graph")
        error = StringIO()

        with redirect_stderr(error):
            status = CONVENTIONAL_VERSION.main(
                ["--repository", str(self.repository), "--format", "selector"]
            )

        self.assertEqual(status, 2)
        self.assertIn("no release-producing", error.getvalue())

        output = StringIO()
        with redirect_stdout(output):
            status = CONVENTIONAL_VERSION.main(
                [
                    "--repository",
                    str(self.repository),
                    "--format",
                    "selector",
                    "--allow-no-release",
                ]
            )
        self.assertEqual(status, 0)
        self.assertEqual(output.getvalue(), "\n")

    def test_nonconventional_commit_fails_closed(self) -> None:
        self.commit("update the build")

        with self.assertRaisesRegex(
            CONVENTIONAL_VERSION.VersionError,
            "not Conventional Commits compliant",
        ):
            CONVENTIONAL_VERSION.plan(self.repository)

    def test_merge_commit_uses_its_conventional_pull_request_title(self) -> None:
        commit = CONVENTIONAL_VERSION.Commit(
            "a" * 40,
            "Merge pull request #1 from example/topic",
            "fix(runtime): retain result",
        )

        self.assertEqual(CONVENTIONAL_VERSION.commit_level(commit), "patch")

    def test_empty_merge_commit_is_ignored(self) -> None:
        commit = CONVENTIONAL_VERSION.Commit(
            "a" * 40,
            "Merge pull request #1 from example/topic",
            "",
        )

        self.assertIsNone(CONVENTIONAL_VERSION.commit_level(commit))

    def test_cli_formats_are_stable(self) -> None:
        self.commit("perf: reduce startup allocation")
        output = StringIO()

        with redirect_stdout(output):
            status = CONVENTIONAL_VERSION.main(
                ["--repository", str(self.repository), "--format", "version"]
            )

        self.assertEqual(status, 0)
        self.assertEqual(output.getvalue(), "1.2.4\n")

        output = StringIO()
        with redirect_stdout(output):
            status = CONVENTIONAL_VERSION.main(
                ["--repository", str(self.repository)]
            )
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue())["selector"], "--+")

    def test_version_rejects_leading_zero(self) -> None:
        with self.assertRaisesRegex(CONVENTIONAL_VERSION.VersionError, "not bare"):
            CONVENTIONAL_VERSION.Version.parse("01.2.3")


if __name__ == "__main__":
    unittest.main()
