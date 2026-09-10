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
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path


SCRIPT = Path(__file__).with_name("release-dispatch-journal.py")
SPEC = importlib.util.spec_from_file_location("release_dispatch_journal", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseDispatchJournalTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "retained"
        self.request = "12345678-1234-1234-1234-123456789abc"

    def invoke(self, *arguments: str) -> int:
        with redirect_stdout(StringIO()):
            return MODULE.main([*arguments, "--root", str(self.root), "--request-id", self.request])

    def test_intent_then_ack_is_atomic_and_durable(self) -> None:
        self.assertEqual(
            self.invoke(
                "intent",
                "--workflow",
                "docs.yml",
                "--version",
                "0.15.0",
                "--control-sha",
                "a" * 40,
            ),
            0,
        )
        path = MODULE.record_path(self.root, self.request)
        self.assertEqual(json.loads(path.read_text())["state"], "dispatch-intent")
        self.assertEqual(self.invoke("ack", "--run-id", "987"), 0)
        record = json.loads(path.read_text())
        self.assertEqual(record["state"], "dispatched")
        self.assertEqual(record["run_id"], "987")

    def test_ack_without_intent_is_rejected(self) -> None:
        self.assertEqual(self.invoke("ack", "--run-id", "987"), 2)

    def test_invalid_version_and_tampered_intent_are_rejected(self) -> None:
        self.assertEqual(
            self.invoke(
                "intent",
                "--workflow",
                "docs.yml",
                "--version",
                "latest",
                "--control-sha",
                "a" * 40,
            ),
            2,
        )
        self.assertEqual(
            self.invoke(
                "intent",
                "--workflow",
                "docs.yml",
                "--version",
                "0.15.0",
                "--control-sha",
                "a" * 40,
            ),
            0,
        )
        path = MODULE.record_path(self.root, self.request)
        record = json.loads(path.read_text())
        record["request_id"] = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        path.write_text(json.dumps(record))

        self.assertEqual(self.invoke("ack", "--run-id", "987"), 2)

    def test_unknown_response_is_durable_and_can_be_reconciled(self) -> None:
        self.assertEqual(
            self.invoke(
                "intent",
                "--workflow",
                "docs.yml",
                "--version",
                "0.15.0",
                "--control-sha",
                "a" * 40,
            ),
            0,
        )
        self.assertEqual(self.invoke("unknown"), 0)
        path = MODULE.record_path(self.root, self.request)
        self.assertEqual(json.loads(path.read_text())["state"], "dispatch-unknown")
        self.assertEqual(self.invoke("ack", "--run-id", "987"), 0)
        self.assertEqual(json.loads(path.read_text())["state"], "dispatched")


if __name__ == "__main__":
    unittest.main()
