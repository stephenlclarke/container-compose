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

"""Tests for candidate-bound stable release authority receipts."""

import argparse
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("stable-release-authority.py")
SPEC = importlib.util.spec_from_file_location("stable_release_authority", MODULE_PATH)
assert SPEC and SPEC.loader
AUTHORITY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUTHORITY
SPEC.loader.exec_module(AUTHORITY)


class StableReleaseAuthorityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        self.refs = {
            "container-compose": "a" * 40,
            "container-builder-shim": "b" * 40,
            "containerization": "c" * 40,
            "container": "d" * 40,
            "homebrew-tap": "e" * 40,
        }
        self.output = self.evidence / "hosted-sibling-stack.example.log"
        self.output.write_text("validated\n", encoding="utf-8")
        self.checkpoint = self.evidence / "hosted-sibling-stack.success.json"
        self.checkpoint.write_text(
            json.dumps(
                {
                    "digest": "1" * 64,
                    "duration_seconds": 123.5,
                    "fingerprint": "exact candidate inputs",
                    "fingerprint_after": "exact candidate inputs",
                    "fingerprint_before": "exact candidate inputs",
                    "output_file": self.output.name,
                    "output_sha256": AUTHORITY.sha256_file(self.output),
                    "schema": 4,
                    "stage": "hosted-sibling-stack",
                    "status": 0,
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        self.receipt = self.root / "receipt.json"

    def arguments(self, **overrides: str) -> argparse.Namespace:
        values = {
            "evidence_dir": str(self.evidence),
            "receipt": str(self.receipt),
            "release_tag": "0.15.0",
            "candidate_sha": self.refs["container-compose"],
            "builder_ref": self.refs["container-builder-shim"],
            "containerization_ref": self.refs["containerization"],
            "container_ref": self.refs["container"],
            "homebrew_tap_ref": self.refs["homebrew-tap"],
            "init_image_sha256": "f" * 64,
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_receipt_binds_inputs_and_success_checkpoint(self) -> None:
        expected = AUTHORITY.build_receipt(self.arguments())
        AUTHORITY.write_receipt(expected, self.receipt)
        actual = json.loads(self.receipt.read_text(encoding="utf-8"))

        self.assertEqual(actual, expected)
        self.assertEqual(actual["schema"], 2)
        self.assertEqual(actual["candidateSha"], "a" * 40)
        self.assertEqual(actual["components"]["container"], "d" * 40)
        self.assertEqual(actual["buildEvidence"]["durationSeconds"], 123.5)
        self.assertRegex(actual["packageInputsSha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o444)

    def test_changed_package_input_or_evidence_changes_receipt(self) -> None:
        original = AUTHORITY.build_receipt(self.arguments())
        changed_input = AUTHORITY.build_receipt(
            self.arguments(init_image_sha256="0" * 64)
        )
        self.output.write_text("different output\n", encoding="utf-8")
        checkpoint = json.loads(self.checkpoint.read_text(encoding="utf-8"))
        checkpoint["output_sha256"] = AUTHORITY.sha256_file(self.output)
        self.checkpoint.write_text(json.dumps(checkpoint), encoding="utf-8")
        changed_evidence = AUTHORITY.build_receipt(self.arguments())

        self.assertNotEqual(
            original["packageInputsSha256"], changed_input["packageInputsSha256"]
        )
        self.assertNotEqual(
            original["buildEvidence"]["checkpointSha256"],
            changed_evidence["buildEvidence"]["checkpointSha256"],
        )

    def test_failed_or_drifted_checkpoint_is_rejected(self) -> None:
        original = self.checkpoint.read_text(encoding="utf-8")
        for field, value, message in (
            ("status", 1, "did not pass"),
            ("fingerprint_after", "drifted", "inputs changed"),
            ("duration_seconds", float("inf"), "duration is invalid"),
        ):
            with self.subTest(field=field):
                checkpoint = json.loads(original)
                checkpoint[field] = value
                self.checkpoint.write_text(json.dumps(checkpoint), encoding="utf-8")
                with self.assertRaisesRegex(SystemExit, message):
                    AUTHORITY.build_receipt(self.arguments())
        self.checkpoint.write_text(original, encoding="utf-8")

    def test_changed_or_indirect_output_is_rejected(self) -> None:
        self.output.write_text("tampered\n", encoding="utf-8")
        with self.assertRaisesRegex(SystemExit, "output changed"):
            AUTHORITY.build_receipt(self.arguments())

        self.output.unlink()
        destination = self.root / "retained.log"
        destination.write_text("validated\n", encoding="utf-8")
        self.output.symlink_to(destination)
        with self.assertRaisesRegex(SystemExit, "indirect or missing"):
            AUTHORITY.build_receipt(self.arguments())

    def test_indirect_evidence_is_rejected(self) -> None:
        indirect = self.root / "indirect"
        indirect.symlink_to(self.evidence, target_is_directory=True)
        with self.assertRaisesRegex(SystemExit, "evidence is indirect"):
            AUTHORITY.build_receipt(self.arguments(evidence_dir=str(indirect)))

    def test_incomplete_input_identity_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "not immutable"):
            AUTHORITY.build_receipt(self.arguments(container_ref="main"))

    def test_existing_receipt_is_never_replaced(self) -> None:
        self.receipt.write_text("retained\n", encoding="utf-8")
        with self.assertRaisesRegex(SystemExit, "refusing to replace"):
            AUTHORITY.write_receipt(
                AUTHORITY.build_receipt(self.arguments()), self.receipt
            )
        self.assertEqual(self.receipt.read_text(encoding="utf-8"), "retained\n")

    def test_verifier_rejects_tampered_and_malformed_receipts(self) -> None:
        expected = AUTHORITY.build_receipt(self.arguments())
        AUTHORITY.write_receipt(expected, self.receipt)
        self.assertEqual(
            AUTHORITY.verify_receipt(expected, self.receipt),
            AUTHORITY.sha256_file(self.receipt),
        )

        self.receipt.chmod(0o644)
        self.receipt.write_text(
            self.receipt.read_text(encoding="utf-8").replace("a" * 40, "0" * 40),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(SystemExit, "does not match its evidence"):
            AUTHORITY.verify_receipt(expected, self.receipt)
        self.receipt.write_text("{not-json}\n", encoding="utf-8")
        with self.assertRaisesRegex(SystemExit, "receipt is malformed"):
            AUTHORITY.verify_receipt(expected, self.receipt)

    def test_temporary_output_is_removed_after_write_failure(self) -> None:
        expected = AUTHORITY.build_receipt(self.arguments())
        temporary = self.receipt.with_name(f".{self.receipt.name}.{os.getpid()}.tmp")
        with mock.patch.object(os, "replace", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                AUTHORITY.write_receipt(expected, self.receipt)
        self.assertFalse(temporary.exists())
        self.assertFalse(self.receipt.exists())


if __name__ == "__main__":
    unittest.main()
