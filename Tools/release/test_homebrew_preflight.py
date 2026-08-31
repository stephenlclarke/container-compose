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

"""Tests for the Homebrew release preflight."""

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("homebrew-preflight.py")
SPEC = importlib.util.spec_from_file_location("homebrew_preflight", MODULE_PATH)
assert SPEC and SPEC.loader
PREFLIGHT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PREFLIGHT
SPEC.loader.exec_module(PREFLIGHT)


def formula(class_name: str, tag: str, asset: str, version: str | None = None) -> str:
    version_line = f'  version "{version}"\n' if version else ""
    return (
        f"class {class_name} < Formula\n"
        f'  url "https://github.com/stephenlclarke/container-compose/releases/download/{tag}/{asset}"\n'
        f'  sha256 "{'a' * 64}"\n'
        f"{version_line}"
        "end\n"
    )


class HomebrewPreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.tap = Path(self.temporary_directory.name)
        (self.tap / "Formula").mkdir()
        subprocess.run(["git", "-C", str(self.tap), "init", "-q"], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(self.tap),
                "remote",
                "add",
                "origin",
                "https://github.com/stephenlclarke/homebrew-tap.git",
            ],
            check=True,
        )
        current_version = "current.42.0123456789ab"
        fixtures = {
            "container": formula(
                "Container", "0.14.0", "container-release-arm64.tar.gz"
            ),
            "container-compose": formula(
                "ContainerCompose",
                "0.14.0",
                "container-compose-plugin-release-arm64.tar.gz",
            ),
            "container-current": formula(
                "ContainerCurrent",
                "current",
                "container-current-0123456789ab-arm64.tar.gz",
                current_version,
            ),
            "container-compose-current": formula(
                "ContainerComposeCurrent",
                "current",
                "container-compose-plugin-current-0123456789ab-arm64.tar.gz",
                current_version,
            ),
        }
        for name, contents in fixtures.items():
            (self.tap / "Formula" / f"{name}.rb").write_text(contents, encoding="utf-8")
        subprocess.run(["git", "-C", str(self.tap), "add", "--all"], check=True)
        subprocess.run(
            ["git", "-C", str(self.tap), "-c", "user.name=Tests", "-c", "user.email=tests@example.com", "commit", "-q", "-m", "fixtures"],
            check=True,
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_accepts_matched_stable_and_current_formula_pairs(self) -> None:
        formulae = PREFLIGHT.validate_tap(self.tap, require_clean=True)

        self.assertEqual(formulae["container"].release_tag, "0.14.0")
        self.assertEqual(
            formulae["container-current"].version,
            formulae["container-compose-current"].version,
        )

    def test_rejects_mismatched_stable_formulae(self) -> None:
        path = self.tap / "Formula" / "container-compose.rb"
        path.write_text(
            formula(
                "ContainerCompose",
                "0.13.0",
                "container-compose-plugin-release-arm64.tar.gz",
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ValueError, "do not use the same release tag"):
            PREFLIGHT.validate_tap(self.tap, require_clean=False)

    def test_rejects_dirty_tap_before_release(self) -> None:
        (self.tap / "unexpected.txt").write_text("dirty\n", encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "uncommitted changes"):
            PREFLIGHT.validate_tap(self.tap, require_clean=True)

    def test_rejects_stable_formula_with_explicit_version(self) -> None:
        path = self.tap / "Formula" / "container.rb"
        path.write_text(
            formula(
                "Container",
                "0.14.0",
                "container-release-arm64.tar.gz",
                "0.14.0",
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ValueError, "must derive its version"):
            PREFLIGHT.validate_tap(self.tap, require_clean=False)


if __name__ == "__main__":
    unittest.main()
