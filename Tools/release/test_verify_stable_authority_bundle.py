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

import argparse
import hashlib
import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-stable-authority-bundle.py")
SPEC = importlib.util.spec_from_file_location("verify_stable_authority_bundle", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class VerifyStableAuthorityBundleTests(unittest.TestCase):
    def fixture(self, root: Path) -> tuple[Path, argparse.Namespace]:
        values = {
            "candidate_sha": "a" * 40,
            "builder_ref": "b" * 40,
            "containerization_ref": "c" * 40,
            "container_ref": "d" * 40,
            "init_image_sha256": "e" * 64,
        }
        output_name = "hosted-output.log"
        output = b"verified\n"
        fingerprint = "immutable inputs"
        checkpoint = {
            "schema": 4,
            "stage": "hosted-sibling-stack",
            "status": 0,
            "digest": "f" * 64,
            "fingerprint": fingerprint,
            "fingerprint_before": "same",
            "fingerprint_after": "same",
            "duration_seconds": 1.25,
            "output_file": output_name,
            "output_sha256": hashlib.sha256(output).hexdigest(),
        }
        checkpoint_bytes = (json.dumps(checkpoint, sort_keys=True) + "\n").encode()
        components = {
            "container-builder-shim": values["builder_ref"],
            "containerization": values["containerization_ref"],
            "container": values["container_ref"],
            "homebrew-tap": "1" * 40,
        }
        package_inputs = {
            "candidateSha": values["candidate_sha"],
            "components": components,
            "guestInitImageSha256": values["init_image_sha256"],
        }
        receipt = {
            "schema": 2,
            "result": "success",
            "releaseTag": "1.2.3",
            **package_inputs,
            "packageInputsSha256": hashlib.sha256(
                json.dumps(
                    package_inputs, sort_keys=True, separators=(",", ":")
                ).encode()
            ).hexdigest(),
            "buildEvidence": {
                "checkpointSha256": hashlib.sha256(checkpoint_bytes).hexdigest(),
                "durationSeconds": checkpoint["duration_seconds"],
                "fingerprintSha256": hashlib.sha256(fingerprint.encode()).hexdigest(),
                "outputFile": output_name,
                "outputSha256": hashlib.sha256(output).hexdigest(),
                "stage": "hosted-sibling-stack",
            },
        }
        receipt_bytes = (json.dumps(receipt, sort_keys=True) + "\n").encode()
        archive = root / "stable-release-authority.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            for name, payload in {
                "stable-release-authority.json": receipt_bytes,
                "hosted-sibling-stack.success.json": checkpoint_bytes,
                output_name: output,
            }.items():
                member = tarfile.TarInfo(f"./{name}")
                member.size = len(payload)
                bundle.addfile(member, io.BytesIO(payload))
        return archive, argparse.Namespace(
            archive=archive,
            release_tag="1.2.3",
            receipt_sha256=hashlib.sha256(receipt_bytes).hexdigest(),
            **values,
        )

    def test_verified_bundle_binds_every_release_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive, options = self.fixture(Path(directory))
            receipt_digest, homebrew_ref = MODULE.verify_bundle(options)
            self.assertEqual(receipt_digest, options.receipt_sha256)
            self.assertEqual(homebrew_ref, "1" * 40)

            options.container_ref = "2" * 40
            with self.assertRaisesRegex(MODULE.AuthorityBundleError, "container"):
                MODULE.verify_bundle(options)

    def test_bundle_rejects_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive, options = self.fixture(Path(directory))
            with tarfile.open(archive, "w:gz") as bundle:
                payload = b"unsafe"
                member = tarfile.TarInfo("../receipt.json")
                member.size = len(payload)
                bundle.addfile(member, io.BytesIO(payload))
            with self.assertRaisesRegex(MODULE.AuthorityBundleError, "unsafe"):
                MODULE.verify_bundle(options)


if __name__ == "__main__":
    unittest.main()
