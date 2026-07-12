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

import contextlib
import io
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("resolve-containerization-pin.py")
SPEC = importlib.util.spec_from_file_location("resolve_containerization_pin", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
resolver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resolver)


def write_resolved(path: Path, pins: list[dict]) -> None:
    path.write_text(json.dumps({"pins": pins}), encoding="utf-8")


def containerization_pin(revision: str) -> dict:
    return {
        "identity": "containerization",
        "kind": "remoteSourceControl",
        "location": "https://github.com/stephenlclarke/containerization.git",
        "state": {"branch": "main", "revision": revision},
    }


class ResolveContainerizationPinTest(unittest.TestCase):
    def test_prefers_first_resolved_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            first = Path(tmp) / "first.resolved"
            second = Path(tmp) / "second.resolved"
            write_resolved(first, [containerization_pin("compose-ref")])
            write_resolved(second, [containerization_pin("container-ref")])

            pin = resolver.first_pin([first, second], "containerization")

            self.assertEqual(resolver.ref_value(pin), "compose-ref")
            self.assertEqual(resolver.source_value(pin), "stephenlclarke/containerization")

    def test_falls_back_to_later_resolved_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            first = Path(tmp) / "first.resolved"
            second = Path(tmp) / "second.resolved"
            write_resolved(first, [])
            write_resolved(second, [containerization_pin("container-ref")])

            pin = resolver.first_pin([first, second], "containerization")

            self.assertEqual(resolver.ref_value(pin), "container-ref")

    def test_missing_pin_is_unspecified(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            resolved = Path(tmp) / "Package.resolved"
            write_resolved(resolved, [])

            pin = resolver.first_pin([resolved], "containerization")

            self.assertEqual(resolver.source_value(pin), "unspecified")
            self.assertEqual(resolver.ref_value(pin), "unspecified")

    def test_main_prints_requested_field(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            resolved = Path(tmp) / "Package.resolved"
            write_resolved(resolved, [containerization_pin("resolved-ref")])
            output = io.StringIO()

            with mock.patch(
                "sys.argv",
                ["resolve-containerization-pin.py", "--field", "ref", "--resolved", str(resolved)],
            ), contextlib.redirect_stdout(output):
                status = resolver.main()

            self.assertEqual(status, 0)
            self.assertEqual(output.getvalue().strip(), "resolved-ref")


if __name__ == "__main__":
    unittest.main()
