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
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("stack-artifact.py")
SPEC = importlib.util.spec_from_file_location("stack_artifact", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
STACK_ARTIFACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STACK_ARTIFACT)


class StackArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "external/build/compose"
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(b"binary\n")
        self.source.chmod(0o755)
        self.retained = self.root / "local/retained"

    def test_promotes_content_addressed_read_only_artifact(self) -> None:
        result = STACK_ARTIFACT.promote(self.source, self.retained, "compose")

        self.assertTrue(result.is_file())
        self.assertEqual(result.read_bytes(), b"binary\n")
        self.assertEqual(stat.S_IMODE(result.stat().st_mode), 0o555)
        self.assertEqual(result.parts[-4], "sha256")
        self.assertFalse(str(result).startswith(str(self.source.parent)))

    def test_reuses_identical_promoted_artifact(self) -> None:
        first = STACK_ARTIFACT.promote(self.source, self.retained, "compose")
        second = STACK_ARTIFACT.promote(self.source, self.retained, "compose")

        self.assertEqual(first, second)

    def test_rejects_symlink_source_and_unsafe_name(self) -> None:
        link = self.root / "link"
        link.symlink_to(self.source)
        with self.assertRaisesRegex(STACK_ARTIFACT.ArtifactError, "regular file"):
            STACK_ARTIFACT.promote(link, self.retained, "compose")
        with self.assertRaisesRegex(STACK_ARTIFACT.ArtifactError, "path component"):
            STACK_ARTIFACT.promote(self.source, self.retained, "../compose")

    def test_existing_conflicting_object_is_rejected(self) -> None:
        destination = STACK_ARTIFACT.promote(self.source, self.retained, "compose")
        os.chmod(destination, 0o755)
        with self.assertRaisesRegex(STACK_ARTIFACT.ArtifactError, "mode conflicts"):
            STACK_ARTIFACT.promote(self.source, self.retained, "compose")

    def test_rejects_symlinked_object_store_ancestor(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        self.retained.mkdir(parents=True)
        (self.retained / "objects").symlink_to(outside, target_is_directory=True)

        with self.assertRaisesRegex(STACK_ARTIFACT.ArtifactError, "symbolic link"):
            STACK_ARTIFACT.promote(self.source, self.retained, "compose")
        self.assertEqual(list(outside.iterdir()), [])

    def test_concurrent_identical_promotion_cannot_replace_retained_bytes(self) -> None:
        original_link = STACK_ARTIFACT.os.link

        def race(source: Path, destination: Path, **options: object) -> None:
            destination.write_bytes(b"binary\n")
            destination.chmod(0o555)
            original_link(source, destination, **options)

        with mock.patch.object(STACK_ARTIFACT.os, "link", side_effect=race):
            result = STACK_ARTIFACT.promote(self.source, self.retained, "compose")

        self.assertEqual(result.read_bytes(), b"binary\n")


if __name__ == "__main__":
    unittest.main()
