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
from collections.abc import Sequence
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).with_name("package-publication-authority.py")
SPEC = importlib.util.spec_from_file_location("package_publication_authority", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
AUTHORITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTHORITY)


class PackagePublicationAuthorityTests(unittest.TestCase):
    release_ref = "a" * 40
    asset_digest = "b" * 64
    tap_ref = "c" * 40

    def options(self, *extra: str) -> argparse.Namespace:
        return AUTHORITY.parse_arguments(
            (
                "--repository",
                "owner/compose",
                "--release-tag",
                "1.2.3",
                "--release-ref",
                self.release_ref,
                "--release-prerelease",
                "false",
                "--asset",
                f"compose.tar.gz={self.asset_digest}",
                *extra,
            )
        )

    def command_result(
        self, arguments: Sequence[str], cwd: Path | None = None
    ) -> str:
        del cwd
        joined = " ".join(arguments)
        if "releases/tags/1.2.3" in joined:
            return (
                '{"id":12,"tag_name":"1.2.3","draft":false,'
                '"prerelease":false,"assets":['
                f'{{"name":"compose.tar.gz","digest":"sha256:{self.asset_digest}"}}]}}'
            )
        if "https://github.com/owner/compose.git" in joined:
            return f"{self.release_ref}\trefs/tags/1.2.3"
        if arguments[:3] == ("git", "rev-parse", "HEAD"):
            return self.tap_ref
        if arguments[:3] == ("git", "ls-remote", "--heads"):
            return f"{self.tap_ref}\trefs/heads/main"
        if arguments[:3] == ("git", "status", "--porcelain"):
            return ""
        if arguments[:2] == ("ruby", "-c"):
            return "Syntax OK"
        raise AssertionError(arguments)

    def test_unchanged_release_and_tap_have_a_stable_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tap = Path(directory)
            formula = tap / "Formula" / "container-compose.rb"
            formula.parent.mkdir()
            formula.write_text(
                "class ContainerCompose < Formula\n"
                '  url "https://github.com/owner/compose/releases/download/'
                '1.2.3/compose.tar.gz"\n'
                f'  sha256 "{self.asset_digest}"\n'
                "end\n",
                encoding="utf-8",
            )
            options = self.options(
                "--tap",
                str(tap),
                "--tap-ref",
                self.tap_ref,
                "--formula",
                str(formula),
            )

            with mock.patch.object(
                AUTHORITY, "run_command", side_effect=self.command_result
            ):
                first = AUTHORITY.authority_digest(options)
                second = AUTHORITY.authority_digest(options)

        self.assertRegex(first, r"^[0-9a-f]{64}$")
        self.assertEqual(first, second)

    def test_changed_published_asset_is_rejected(self) -> None:
        def changed(arguments: Sequence[str]) -> str:
            result = self.command_result(arguments)
            if "releases/tags/1.2.3" in " ".join(arguments):
                return result.replace(self.asset_digest, "d" * 64)
            return result

        with mock.patch.object(AUTHORITY, "run_command", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "published asset changed"):
                AUTHORITY.authority_digest(self.options())

    def test_moved_release_tag_is_rejected(self) -> None:
        def changed(arguments: Sequence[str]) -> str:
            if "https://github.com/owner/compose.git" in " ".join(arguments):
                return f"{'d' * 40}\trefs/tags/1.2.3"
            return self.command_result(arguments)

        with mock.patch.object(AUTHORITY, "run_command", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "release tag moved"):
                AUTHORITY.authority_digest(self.options())


if __name__ == "__main__":
    unittest.main()
