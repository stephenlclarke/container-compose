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

"""Tests for the deterministic Swift style toolchain."""

import hashlib
import importlib.util
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("swift-style.py")
SPEC = importlib.util.spec_from_file_location("swift_style", MODULE_PATH)
assert SPEC and SPEC.loader
STYLE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = STYLE
SPEC.loader.exec_module(STYLE)


class SwiftStyleTests(unittest.TestCase):
    """Selection and installation use one fail-closed policy."""

    def test_style_paths_select_supported_existing_files(self) -> None:
        selected = STYLE.style_paths(
            (
                "Package.swift",
                "Sources/ComposeCore/ComposeAPISocketTransform.swift",
                "Tests/ComposeCoreTests/ComposeAPISocketTests.swift",
                "Sources/ComposePlugin/ComposePlugin.swift",
                "docs/project/STATUS.md",
                "Sources/ComposeCore/Missing.swift",
            )
        )

        self.assertEqual(
            selected,
            (
                "Package.swift",
                "Sources/ComposeCore/ComposeAPISocketTransform.swift",
                "Tests/ComposeCoreTests/ComposeAPISocketTests.swift",
            ),
        )

    def test_policy_only_diff_selects_all_maintained_swift_paths(self) -> None:
        for policy_path in STYLE.STYLE_POLICY_PATHS:
            with self.subTest(policy_path=policy_path):
                environment = {"SWIFT_STYLE_BASE": "base", "SWIFT_STYLE_HEAD": "head"}
                with mock.patch.dict(os.environ, environment, clear=True):
                    with mock.patch.object(
                        STYLE,
                        "git",
                        side_effect=(
                            policy_path + "\n",
                            "Package.swift\nSources/ComposeCore/ComposeAPISocketTransform.swift\n",
                        ),
                    ) as git:
                        selected = STYLE.style_paths(STYLE.changed_paths())
                self.assertEqual(
                    selected,
                    ("Package.swift", "Sources/ComposeCore/ComposeAPISocketTransform.swift"),
                )
                self.assertEqual(git.call_count, 2)

    def test_ordinary_diff_keeps_narrow_changed_path_selection(self) -> None:
        environment = {"SWIFT_STYLE_BASE": "base", "SWIFT_STYLE_HEAD": "head"}
        with mock.patch.dict(os.environ, environment, clear=True):
            with mock.patch.object(
                STYLE,
                "git",
                return_value="Sources/ComposeCore/ComposeAPISocketTransform.swift\ndocs/README.md\n",
            ) as git:
                selected = STYLE.style_paths(STYLE.changed_paths())
        self.assertEqual(selected, ("Sources/ComposeCore/ComposeAPISocketTransform.swift",))
        git.assert_called_once_with("diff", "--no-renames", "--name-only", "--diff-filter=ACMRD", "base...head")

    def test_renamed_policy_file_selects_all_maintained_swift_paths(self) -> None:
        environment = {"SWIFT_STYLE_BASE": "base", "SWIFT_STYLE_HEAD": "head"}
        with mock.patch.dict(os.environ, environment, clear=True):
            with mock.patch.object(
                STYLE,
                "git",
                side_effect=(".swiftformat\nconfig/swiftformat\n", "Package.swift\n"),
            ) as git:
                selected = STYLE.style_paths(STYLE.changed_paths())
        self.assertEqual(selected, ("Package.swift",))
        self.assertEqual(git.call_count, 2)

    def test_required_style_check_uses_maintained_paths_when_diff_has_no_swift(self) -> None:
        environment = {
            "SWIFT_STYLE_BASE": "base",
            "SWIFT_STYLE_HEAD": "head",
            "SWIFT_STYLE_REQUIRE_PATHS": "1",
        }
        with mock.patch.dict(os.environ, environment, clear=True):
            with mock.patch.object(
                STYLE,
                "git",
                side_effect=("Tools/bazel/run.py\n", "Package.swift\nSources/ComposeCore/ComposeAPISocketTransform.swift\n"),
            ) as git:
                selected = STYLE.selected_style_paths()
        self.assertEqual(selected, ("Package.swift", "Sources/ComposeCore/ComposeAPISocketTransform.swift"))
        self.assertEqual(git.call_count, 2)

    def test_required_style_check_rejects_empty_maintained_inventory(self) -> None:
        with mock.patch.dict(os.environ, {"SWIFT_STYLE_REQUIRE_PATHS": "1"}, clear=True):
            with mock.patch.object(STYLE, "git", side_effect=("Tools/bazel/run.py\n", "")):
                with self.assertRaisesRegex(SystemExit, "No maintained Swift style paths"):
                    STYLE.selected_style_paths()

    def test_workflow_classifies_release_eligible_non_swift_changes(self) -> None:
        workflow = (STYLE.ROOT / ".github/workflows/quality.yml").read_text(encoding="utf-8").splitlines()
        start = workflow.index("          heavy=false")
        end = workflow.index("          printf 'swift=%s\\n' \"$swift\" >> \"$GITHUB_OUTPUT\"")
        classifier = "set -euo pipefail\n" + "\n".join(line[10:] for line in workflow[start : end + 1])
        cases = (
            ("docs/README.md\n", "heavy=false\nswift=false\n"),
            ("Sources/README.md\n", "heavy=false\nswift=true\n"),
            ("Tools/bazel/run.py\n", "heavy=true\nswift=false\n"),
            (".swiftlint.yml\n", "heavy=true\nswift=true\n"),
            ("Sources/ComposeCore/Feature.swift\n", "heavy=true\nswift=true\n"),
            ("", "heavy=true\nswift=false\n"),
        )
        for changed, expected in cases:
            with self.subTest(changed=changed):
                with tempfile.TemporaryDirectory() as temporary:
                    changed_file = Path(temporary) / "changed-files.txt"
                    output_file = Path(temporary) / "output.txt"
                    changed_file.write_text(changed, encoding="utf-8")
                    environment = {**os.environ, "changed_files": str(changed_file), "GITHUB_OUTPUT": str(output_file)}
                    subprocess.run(["bash", "-c", classifier], env=environment, check=True)
                    self.assertEqual(output_file.read_text(encoding="utf-8"), expected)
        self.assertIn(
            "if: github.event_name != 'schedule' && needs.changes.outputs.heavy == 'true'",
            "\n".join(workflow),
        )

    def test_install_tool_verifies_archive_and_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_archive = root / "source.zip"
            payload = b"#!/bin/sh\nprintf '1.2.3\\n'\n"
            with zipfile.ZipFile(source_archive, "w") as archive:
                archive.writestr("fixture", payload)
            tool = STYLE.Tool(
                name="fixture",
                version="1.2.3",
                url="https://example.invalid/fixture.zip",
                archive_sha256=hashlib.sha256(source_archive.read_bytes()).hexdigest(),
                member="fixture",
                executable_sha256=hashlib.sha256(payload).hexdigest(),
            )

            def copy_archive(_url: str, destination: Path) -> None:
                shutil.copyfile(source_archive, destination)

            installed = STYLE.install_tool(tool, root / "cache", copy_archive)

            self.assertEqual(installed.read_bytes(), payload)
            self.assertTrue(installed.stat().st_mode & stat.S_IXUSR)
            self.assertEqual(STYLE.install_tool(tool, root / "cache", copy_archive), installed)

    def test_install_tool_rejects_untrusted_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_archive = root / "source.zip"
            with zipfile.ZipFile(source_archive, "w") as archive:
                archive.writestr("fixture", b"untrusted")
            tool = STYLE.Tool(
                name="fixture",
                version="1.0.0",
                url="https://example.invalid/fixture.zip",
                archive_sha256="0" * 64,
                member="fixture",
                executable_sha256="0" * 64,
            )

            def copy_archive(_url: str, destination: Path) -> None:
                shutil.copyfile(source_archive, destination)

            with self.assertRaisesRegex(SystemExit, "archive digest mismatch"):
                STYLE.install_tool(tool, root / "cache", copy_archive)


if __name__ == "__main__":
    unittest.main()
