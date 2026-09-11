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

    def test_find_returns_existing_logical_operation(self) -> None:
        self.assertEqual(
            self.invoke(
                "intent",
                "--workflow",
                "docs.yml",
                "--version",
                "0.15.0",
                "--control-sha",
                "a" * 40,
                "--mode",
                "docs",
            ),
            0,
        )
        output = StringIO()
        with redirect_stdout(output):
            result = MODULE.main(
                [
                    "find",
                    "--root",
                    str(self.root),
                    "--workflow",
                    "docs.yml",
                    "--version",
                    "0.15.0",
                    "--control-sha",
                    "a" * 40,
                    "--mode",
                    "docs",
                ]
            )
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output.getvalue())["request_id"], self.request)

    def test_find_run_recovers_the_original_logical_mode(self) -> None:
        common = [
            "--workflow",
            "docs.yml",
            "--version",
            "0.15.0",
            "--control-sha",
            "a" * 40,
            "--mode",
            "docs-regenerate-731",
        ]
        self.assertEqual(self.invoke("intent", *common), 0)
        self.assertEqual(self.invoke("ack", "--run-id", "987"), 0)
        output = StringIO()
        with redirect_stdout(output):
            result = MODULE.main(
                [
                    "find-run",
                    "--root",
                    str(self.root),
                    "--workflow",
                    "docs.yml",
                    "--version",
                    "0.15.0",
                    "--control-sha",
                    "a" * 40,
                    "--run-id",
                    "987",
                ]
            )

        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output.getvalue())["mode"], "docs-regenerate-731")

    def test_claim_reuses_one_logical_operation(self) -> None:
        arguments = [
            "claim", "--root", str(self.root), "--workflow", "docs.yml",
            "--version", "0.15.0", "--control-sha", "a" * 40,
            "--mode", "docs",
        ]
        first_output = StringIO()
        with redirect_stdout(first_output):
            self.assertEqual(
                MODULE.main(arguments + ["--request-id", self.request]), 0
            )
        second_request = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        second_output = StringIO()
        with redirect_stdout(second_output):
            self.assertEqual(
                MODULE.main(arguments + ["--request-id", second_request]), 0
            )
        self.assertEqual(
            json.loads(second_output.getvalue())["request_id"], self.request
        )
        records = list((self.root / "release/dispatches").glob("*.json"))
        self.assertEqual([record.name for record in records], [f"{self.request}.json"])

    def test_failed_acknowledged_attempt_allows_linked_new_claim(self) -> None:
        common = [
            "--workflow", "docs.yml", "--version", "0.15.0",
            "--control-sha", "a" * 40, "--mode", "docs",
        ]
        self.assertEqual(self.invoke("intent", *common), 0)
        self.assertEqual(self.invoke("ack", "--run-id", "987"), 0)
        self.assertEqual(self.invoke("fail"), 0)
        replacement = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(
                MODULE.main(
                    ["claim", "--root", str(self.root), "--request-id", replacement, *common]
                ),
                0,
            )
        record = json.loads(output.getvalue())
        self.assertEqual(record["request_id"], replacement)
        self.assertEqual(record["previous_request_id"], self.request)


if __name__ == "__main__":
    unittest.main()
