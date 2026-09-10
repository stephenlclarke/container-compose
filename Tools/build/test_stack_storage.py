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
from pathlib import Path


SCRIPT = Path(__file__).with_name("stack-storage.py")
SPEC = importlib.util.spec_from_file_location("stack_storage", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class StackStorageTests(unittest.TestCase):
    def arguments(self, retained: Path, transient: Path) -> list[str]:
        return [
            "--retained-root", str(retained),
            "--transient-root", str(transient),
            "--retained-marker", ".retained",
            "--retained-marker-value", "retained-v1",
            "--transient-marker", ".transient",
            "--transient-marker-value", "transient-v1",
            "--retained-path", str(retained / "pins"),
            "--transient-path", str(transient / "scratch"),
        ]

    def test_initializes_role_specific_paths_and_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            retained, transient = root / "retained", root / "transient"
            self.assertEqual(MODULE.main(self.arguments(retained, transient)), 0)
            self.assertTrue((retained / "pins").is_dir())
            self.assertTrue((transient / "scratch").is_dir())

    def test_refuses_to_claim_nonempty_root_before_writing_marker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            retained, transient = root / "retained", root / "transient"
            retained.mkdir()
            (retained / "keep").write_text("keep", encoding="utf-8")
            self.assertEqual(MODULE.main(self.arguments(retained, transient)), 2)
            self.assertFalse((retained / ".retained").exists())
            self.assertFalse(transient.exists())

    def test_rejects_role_escape(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            retained, transient = root / "retained", root / "transient"
            arguments = self.arguments(retained, transient)
            arguments.extend(("--retained-path", str(transient / "wrong")))
            self.assertEqual(MODULE.main(arguments), 2)


if __name__ == "__main__":
    unittest.main()
