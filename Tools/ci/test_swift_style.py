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
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


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
