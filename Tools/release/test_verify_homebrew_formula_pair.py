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


SCRIPT = Path(__file__).with_name("verify-homebrew-formula-pair.py")
SPEC = importlib.util.spec_from_file_location("verify_formula_pair", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FormulaPairTests(unittest.TestCase):
    def test_verifies_the_complete_stable_pair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compose = root / "container-compose.rb"
            runtime = root / "container.rb"
            compose.write_text(
                '  url "https://example.test/compose.tgz"\n'
                f'  sha256 "{"a" * 64}"\n'
                '  depends_on "stephenlclarke/tap/container"\n',
                encoding="utf-8",
            )
            runtime.write_text(
                '  url "https://example.test/runtime.tgz"\n'
                f'  sha256 "{"b" * 64}"\n'
                '  plugin = opt/container-compose/libexec/container-plugins/compose\n',
                encoding="utf-8",
            )
            MODULE.verify(
                compose,
                runtime,
                "https://example.test/compose.tgz",
                "https://example.test/runtime.tgz",
                "a" * 64,
                "b" * 64,
            )

            compose.write_text(compose.read_text() + '  version "1.2.3"\n')
            with self.assertRaisesRegex(MODULE.FormulaError, "derive its version"):
                MODULE.verify(
                    compose,
                    runtime,
                    "https://example.test/compose.tgz",
                    "https://example.test/runtime.tgz",
                    "a" * 64,
                    "b" * 64,
                )

    def test_rejects_duplicate_fields_and_missing_registration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compose = root / "container-compose.rb"
            runtime = root / "container.rb"
            compose.write_text(
                '  url "https://example.test/compose.tgz"\n'
                '  url "https://example.test/other.tgz"\n'
                f'  sha256 "{"a" * 64}"\n'
                '  depends_on "stephenlclarke/tap/container"\n',
                encoding="utf-8",
            )
            runtime.write_text(
                '  url "https://example.test/runtime.tgz"\n'
                f'  sha256 "{"b" * 64}"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(MODULE.FormulaError, "exactly one url"):
                MODULE.verify(
                    compose,
                    runtime,
                    "https://example.test/compose.tgz",
                    "https://example.test/runtime.tgz",
                    "a" * 64,
                    "b" * 64,
                )


if __name__ == "__main__":
    unittest.main()
