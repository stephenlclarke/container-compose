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
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path


SCRIPT = Path(__file__).with_name("stack-transient-clean.py")
SPEC = importlib.util.spec_from_file_location("stack_transient_clean", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class StackTransientCleanTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "transient"
        self.root.mkdir()
        (self.root / MODULE.MARKER).write_text(MODULE.MARKER_VALUE, encoding="utf-8")
        self.retained = Path(temporary.name) / "retained"
        self.retained.mkdir()
        (self.retained / "compose").write_text("keep", encoding="utf-8")
        (self.root / "scratch/nested").mkdir(parents=True)
        (self.root / "scratch/nested/output").write_text("discard", encoding="utf-8")

    def invoke(self, *arguments: str) -> int:
        with redirect_stdout(StringIO()):
            return MODULE.main(["--root", str(self.root), *arguments])

    def test_plan_does_not_delete_transient_or_retained_data(self) -> None:
        self.assertEqual(self.invoke(), 0)
        self.assertTrue((self.root / "scratch/nested/output").exists())
        self.assertTrue((self.retained / "compose").exists())

    def test_execute_removes_only_allowlisted_transient_directories(self) -> None:
        (self.root / "unrelated").write_text("preserve", encoding="utf-8")
        self.assertEqual(self.invoke("--execute"), 0)
        self.assertFalse((self.root / "scratch").exists())
        self.assertTrue((self.root / "unrelated").exists())
        self.assertTrue((self.root / MODULE.MARKER).exists())
        self.assertTrue((self.retained / "compose").exists())

    def test_symlink_target_is_unlinked_without_following_it(self) -> None:
        outside = self.retained / "outside"
        outside.mkdir()
        (outside / "keep").write_text("keep", encoding="utf-8")
        (self.root / "tmp").symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.invoke("--execute"), 0)
        self.assertFalse((self.root / "tmp").exists())
        self.assertTrue((outside / "keep").exists())

    def test_wrong_marker_refuses_cleanup(self) -> None:
        (self.root / MODULE.MARKER).write_text("wrong\n", encoding="utf-8")
        self.assertEqual(self.invoke("--execute"), 2)
        self.assertTrue((self.root / "scratch/nested/output").exists())


if __name__ == "__main__":
    unittest.main()
