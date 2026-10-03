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

"""Regression tests for source-bound stock/enhanced line coverage union."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import merge_profiles as profiles

SHA = "a" * 40
CORE = "Sources/ComposeCore/Core.swift"
SPI = "Sources/ComposeRuntimeSPI/Runtime.swift"
PLUGIN = "Sources/ComposePlugin/Plugin.swift"
ENGINE = "Sources/ComposeEngineRuntime/Engine.swift"
PROVIDER = "Sources/ComposeContainerRuntime/Provider.swift"


class MergeProfilesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in (CORE, SPI, PLUGIN, ENGINE, PROVIDER):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// source\n// line two\n// line three\n")
        self.sources = {name: profiles.digest(self.root / name)
                        for name in (CORE, SPI, PLUGIN, ENGINE, PROVIDER)}
        mock = patch.object(profiles, "source_identity", return_value=self.sources)
        mock.start()
        self.addCleanup(mock.stop)
        self.inputs = self.root / "inputs"
        for profile, runtime in (("enhanced", PROVIDER), ("stock", ENGINE)):
            files = {CORE: {1: profile == "stock", 2: profile == "enhanced", 3: False},
                     SPI: {1: True}, PLUGIN: {1: True}, runtime: {1: True, 2: False}}
            profiles.write_coverage(self.root / "coverage.xml", files)
            profiles.capture(self.root, SHA, profile, self.inputs / profile)

    def test_union_uses_or_and_retains_profile_only_and_uncovered_lines(self) -> None:
        output = self.root / "union"
        receipt = profiles.merge(self.root, SHA, self.inputs, output)
        files = profiles.read_coverage(output / "coverage.xml", self.sources, self.root)
        self.assertEqual(files[CORE], {1: True, 2: True, 3: False})
        self.assertEqual(files[ENGINE], {1: True, 2: False})
        self.assertEqual(files[PROVIDER], {1: True, 2: False})
        self.assertEqual(set(profiles.read_coverage(output / "coverage-provider.xml", self.sources, self.root)), {PROVIDER})
        self.assertEqual(receipt["profiles"], ["enhanced", "stock"])
        self.assertEqual(receipt["coverage_sha256"], profiles.digest(output / "coverage.xml"))
        self.assertEqual(set(receipt["profile_inputs"]), {"enhanced", "stock"})

    def test_same_source_wrong_profile_or_sha_is_rejected(self) -> None:
        path = self.inputs / "stock/receipt.json"
        original = json.loads(path.read_text())
        for key, value in (("source_sha", "b" * 40), ("profile", "enhanced"),
                           ("source_files", {CORE: "wrong"})):
            with self.subTest(key=key):
                profiles.write_json(path, {**original, key: value})
                with self.assertRaisesRegex(ValueError, "identity differs"):
                    profiles.merge(self.root, SHA, self.inputs, self.root / "union")

    def test_missing_profile_cannot_be_a_union(self) -> None:
        (self.inputs / "stock/receipt.json").unlink()
        with self.assertRaises(FileNotFoundError):
            profiles.merge(self.root, SHA, self.inputs, self.root / "union")

    def test_modified_report_is_rejected(self) -> None:
        path = self.inputs / "stock/coverage.xml"
        path.write_text(path.read_text().replace('covered="false"', 'covered="true"'))
        with self.assertRaisesRegex(ValueError, "identity differs"):
            profiles.merge(self.root, SHA, self.inputs, self.root / "union")

    def test_no_runtime_execution_and_wrong_runtime_are_rejected(self) -> None:
        for files in ({CORE: {1: True}}, {ENGINE: {1: False}},
                      {ENGINE: {1: True}, PROVIDER: {1: True}}):
            with self.subTest(files=files):
                profiles.write_coverage(self.root / "coverage.xml", files)
                with self.assertRaisesRegex(ValueError, "runtime"):
                    profiles.capture(self.root, SHA, "stock", self.root / "bad")

    def test_unknown_duplicate_and_invalid_lines_are_rejected(self) -> None:
        path = self.root / "bad.xml"
        for content in (
            '<file path="/tmp/other.swift"><lineToCover lineNumber="1" covered="true"/></file>',
            f'<file path="{CORE}"/><file path="{CORE}"/>',
            f'<file path="{CORE}"><lineToCover lineNumber="0" covered="true"/></file>',
            f'<file path="{CORE}"><lineToCover lineNumber="4" covered="true"/></file>',
            f'<file path="{CORE}"><lineToCover lineNumber="1" covered="yes"/></file>',
            f'<file path="{CORE}"><lineToCover lineNumber="1" covered="true"/><lineToCover lineNumber="1" covered="false"/></file>',
        ):
            with self.subTest(content=content):
                path.write_text('<coverage version="1">' + content + '</coverage>')
                with self.assertRaises(ValueError):
                    profiles.read_coverage(path, self.sources, self.root)

    def test_empty_coverage_is_rejected(self) -> None:
        profiles.write_coverage(self.root / "empty.xml", {})
        with self.assertRaisesRegex(ValueError, "no executable"):
            profiles.read_coverage(self.root / "empty.xml", self.sources, self.root)


class SourceIdentityTests(unittest.TestCase):
    def test_wrong_or_dirty_checkout_fails_before_capture(self) -> None:
        for answers in (("b" * 40,), (SHA, " M Sources/file.swift")):
            with self.subTest(answers=answers), patch.object(profiles, "git", side_effect=answers):
                with self.assertRaisesRegex(ValueError, "exact clean"):
                    profiles.source_identity(Path("."), SHA)

    def test_clean_source_files_are_hashed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / CORE
            source.parent.mkdir(parents=True)
            source.write_text("// first-party source\n")
            with patch.object(profiles, "git", side_effect=(SHA, "", CORE + "\nSources/note.md")):
                self.assertEqual(profiles.source_identity(root, SHA), {CORE: profiles.digest(source)})


if __name__ == "__main__":
    unittest.main()
