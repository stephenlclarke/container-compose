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
    """A successful receipt is complete, immutable, and evidence-bound."""

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
        preflight = self.evidence / "preflight"
        preflight.mkdir()
        repository_summary = []
        for repository, commit in self.refs.items():
            for kind in ("identity", "provenance"):
                receipt = preflight / f"{repository}.{kind}.tsv"
                receipt.write_text(
                    "\n".join(
                        (
                            "schema\t2",
                            f"repository\t{repository}",
                            f"commit\t{commit}",
                            "clean\ttrue",
                            "",
                        )
                    ),
                    encoding="utf-8",
                )
                repository_summary.append(
                    "repository-receipt\t"
                    f"{receipt.name}\t{AUTHORITY.sha256_file(receipt)}"
                )
        (self.evidence / "pipeline-summary.tsv").write_text(
            "\n".join(
                (
                    "schema\t1",
                    "profile\trelease-hosted",
                    f"host-tools-sha256\t{'1' * 64}",
                    f"stage-receipt\tcontainer.receipt.tsv\t{'2' * 64}",
                    f"stage-output\tcontainer.stdout.log\t{'3' * 64}",
                    f"stage-artifact\tcontainer.artifacts.tar\t{'4' * 64}",
                    *repository_summary,
                    "complete\ttrue",
                    "",
                )
            ),
            encoding="utf-8",
        )
        (self.evidence / "attempt.tsv").write_text(
            "\n".join(
                (
                    "schema\t1",
                    "profile\trelease-hosted",
                    "orchestrator-exit\t0",
                    "tee-exit\t0",
                    "evidence-exit\t0",
                    "exit\t0",
                    "",
                )
            ),
            encoding="utf-8",
        )
        (self.evidence / "session.uuid").write_text(
            "01234567-89ab-cdef-0123-456789abcdef\n", encoding="utf-8"
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

    def test_receipt_binds_inputs_toolchain_and_pipeline_evidence(self) -> None:
        expected = AUTHORITY.build_receipt(self.arguments())
        AUTHORITY.write_receipt(expected, self.receipt)
        actual = json.loads(self.receipt.read_text(encoding="utf-8"))

        self.assertEqual(actual, expected)
        self.assertEqual(actual["candidateSha"], "a" * 40)
        self.assertEqual(actual["components"]["container"], "d" * 40)
        self.assertEqual(actual["pipeline"]["hostToolsSha256"], "1" * 64)
        self.assertEqual(len(actual["pipeline"]["evidence"]), 13)
        self.assertRegex(actual["packageInputsSha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o444)

    def test_receipt_changes_when_package_input_or_evidence_changes(self) -> None:
        original = AUTHORITY.build_receipt(self.arguments())
        changed_input = AUTHORITY.build_receipt(
            self.arguments(init_image_sha256="0" * 64)
        )
        (self.evidence / "attempt.tsv").write_text(
            (self.evidence / "attempt.tsv").read_text(encoding="utf-8")
            + "completed-utc\t2026-09-06T10:00:00Z\n",
            encoding="utf-8",
        )
        changed_evidence = AUTHORITY.build_receipt(self.arguments())

        self.assertNotEqual(
            original["packageInputsSha256"],
            changed_input["packageInputsSha256"],
        )
        self.assertNotEqual(
            original["pipeline"]["attemptSha256"],
            changed_evidence["pipeline"]["attemptSha256"],
        )

    def test_failed_attempt_is_rejected(self) -> None:
        attempt = self.evidence / "attempt.tsv"
        attempt.write_text(
            attempt.read_text(encoding="utf-8").replace("exit\t0", "exit\t1"),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(SystemExit, "attempt did not pass"):
            AUTHORITY.build_receipt(self.arguments())

    def test_duplicate_evidence_name_is_rejected(self) -> None:
        summary = self.evidence / "pipeline-summary.tsv"
        summary.write_text(
            summary.read_text(encoding="utf-8")
            + f"stage-receipt\tcontainer.receipt.tsv\t{'2' * 64}\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(SystemExit, "contains duplicates"):
            AUTHORITY.build_receipt(self.arguments())

    def test_repository_receipt_tampering_is_rejected(self) -> None:
        identity = self.evidence / "preflight" / "container.identity.tsv"
        identity.write_text(
            identity.read_text(encoding="utf-8").replace("clean\ttrue", "clean\tfalse"),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(SystemExit, "repository receipt changed"):
            AUTHORITY.build_receipt(self.arguments())

    def test_indirect_evidence_and_preflight_are_rejected(self) -> None:
        indirect_evidence = self.root / "indirect-evidence"
        indirect_evidence.symlink_to(self.evidence, target_is_directory=True)
        with self.assertRaisesRegex(SystemExit, "evidence is indirect"):
            AUTHORITY.build_receipt(
                self.arguments(evidence_dir=str(indirect_evidence))
            )

        preflight = self.evidence / "preflight"
        retained = self.root / "retained-preflight"
        preflight.rename(retained)
        preflight.symlink_to(retained, target_is_directory=True)
        with self.assertRaisesRegex(SystemExit, "preflight is indirect"):
            AUTHORITY.build_receipt(self.arguments())

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
        temporary = self.receipt.with_name(
            f".{self.receipt.name}.{os.getpid()}.tmp"
        )

        with mock.patch.object(AUTHORITY.os, "replace", side_effect=OSError("failed")):
            with self.assertRaisesRegex(OSError, "failed"):
                AUTHORITY.write_receipt(
                    AUTHORITY.build_receipt(self.arguments()), self.receipt
                )
        self.assertFalse(temporary.exists())


if __name__ == "__main__":
    unittest.main()
