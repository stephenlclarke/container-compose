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

import hashlib
import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("historical_reconstruction_benchmark.py")
WORKFLOW = SCRIPT.parents[2] / ".github/workflows/historical-benchmark.yml"
MAKEFILE = SCRIPT.parents[2] / "Makefile"
PIPELINE = SCRIPT.parents[2] / "main.nf"
STAGE_MODULE = SCRIPT.parents[2] / "build-pipeline/modules/repository-stage.nf"
spec = importlib.util.spec_from_file_location("historical_reconstruction_benchmark", SCRIPT)
assert spec and spec.loader
MODULE = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(SCRIPT.parent))
spec.loader.exec_module(MODULE)


class HistoricalReconstructionTests(unittest.TestCase):
    revision = "a" * 40
    run_id = 12345

    def run_record(self, **overrides: object) -> dict[str, object]:
        record: dict[str, object] = {
            "databaseId": self.run_id,
            "workflowName": "Build containerization",
            "headSha": self.revision,
            "status": "completed",
            "conclusion": "success",
            "event": "push",
            "createdAt": "2026-08-24T14:32:14Z",
            "url": (
                "https://github.com/stephenlclarke/containerization/"
                f"actions/runs/{self.run_id}"
            ),
        }
        record.update(overrides)
        return record

    def test_resolves_only_an_exact_successful_source_run(self) -> None:
        resolved = MODULE.resolve_containerization_run(
            [self.run_record(), self.run_record(headSha="b" * 40)], self.revision
        )
        self.assertEqual(resolved["runId"], self.run_id)
        self.assertEqual(resolved["containerizationRef"], self.revision)

        with self.assertRaisesRegex(
            MODULE.ReconstructionInputError, "no successful"
        ):
            MODULE.resolve_containerization_run(
                [self.run_record(conclusion="failure")], self.revision
            )

    def test_requires_one_unexpired_initfs_artifact_bound_to_the_run(self) -> None:
        run = MODULE.resolve_containerization_run([self.run_record()], self.revision)
        payload = {
            "artifacts": [
                {
                    "id": 99,
                    "name": "initfs",
                    "expired": False,
                    "digest": "sha256:" + "c" * 64,
                    "archive_download_url": (
                        "https://api.github.com/repos/stephenlclarke/"
                        "containerization/actions/artifacts/99/zip"
                    ),
                    "workflow_run": {
                        "id": self.run_id,
                        "head_sha": self.revision,
                    },
                }
            ]
        }
        resolved = MODULE.validate_initfs_artifact(payload, run)
        self.assertEqual(resolved["artifactId"], 99)

        payload["artifacts"][0]["expired"] = True
        with self.assertRaisesRegex(
            MODULE.ReconstructionInputError, "expired or does not match"
        ):
            MODULE.validate_initfs_artifact(payload, run)

    def test_extracts_only_the_two_digest_bound_initfs_members(self) -> None:
        with tempfile.TemporaryDirectory(prefix="historical-initfs-") as directory:
            root = Path(directory)
            archive = root / "initfs.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("initfs.ext4", b"ext4")
                bundle.writestr("init.rootfs.tar.gz", b"rootfs")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            output = root / "output"
            MODULE.extract_initfs(archive, f"sha256:{digest}", output)
            self.assertEqual((output / "initfs.ext4").read_bytes(), b"ext4")
            self.assertEqual(
                (output / "init.rootfs.tar.gz").read_bytes(), b"rootfs"
            )

            with self.assertRaisesRegex(
                MODULE.ReconstructionInputError, "digest mismatch"
            ):
                MODULE.extract_initfs(archive, "sha256:" + "0" * 64, root / "bad")

    def test_extracts_a_manifest_authenticated_cctl(self) -> None:
        with tempfile.TemporaryDirectory(prefix="historical-cctl-") as directory:
            root = Path(directory)
            archive = root / "cctl.tar"
            payload = b"exact-cctl"
            with tarfile.open(archive, "w") as bundle:
                member = tarfile.TarInfo("bin/cctl")
                member.size = len(payload)
                member.mode = 0o755
                bundle.addfile(member, io.BytesIO(payload))
            payload_digest = hashlib.sha256(payload).hexdigest()
            archive_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            manifest = root / "cctl.tsv"
            manifest.write_text(
                "schema\t1\n"
                "stage\tcontainerization-benchmark-cctl\n"
                "repository\tcontainerization\n"
                f"artifact\tbin/cctl\t{payload_digest}\t{len(payload)}\n"
                "artifact-count\t1\n"
                f"archive-sha256\t{archive_digest}\n",
                encoding="utf-8",
            )
            output = root / "prepared/cctl"
            result = MODULE.extract_cctl(archive, manifest, output)
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(result["cctlArtifactSha256"], archive_digest)

    def test_prepare_reconstruction_requires_complete_provenance(self) -> None:
        with tempfile.TemporaryDirectory(prefix="historical-provenance-") as directory:
            provenance = Path(directory) / "provenance.json"
            provenance.write_text(json.dumps({"runId": 1}), encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.ReconstructionInputError, "incomplete"
            ):
                MODULE.prepare_reconstruction(
                    "0.13.0",
                    Path(directory),
                    Path(directory),
                    Path(directory),
                    Path(directory),
                    "https://github.test",
                    provenance,
                    Path(directory) / "output",
                )


class HistoricalWorkflowTests(unittest.TestCase):
    def test_workflow_uses_exact_recoverable_authorities(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("runs-on: [self-hosted, macOS, ARM64", workflow)
        self.assertIn("validate-package-artifacts", workflow)
        self.assertIn("verify-developer-id-archive.sh", workflow)
        self.assertIn("validate-initfs", workflow)
        self.assertIn("artifactDigest", workflow)
        self.assertIn("PIPELINE_PROFILE=benchmark-reconstruction", workflow)
        self.assertIn("containerization-benchmark-cctl", workflow)
        self.assertIn("validate-oci-image-layout.py", workflow)

    def test_workflow_keeps_runtime_inputs_local_and_noninteractive(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("BENCHMARK_ROOT: /private/tmp/", workflow)
        self.assertIn("PIPELINE_STATE_ROOT: /Volumes/SSD/github/", workflow)
        self.assertIn("PARITY_INCLUDE_REMOTE_LOGGING=0", workflow)
        self.assertIn("CONTAINER_RUNTIME_LOCAL_EXECUTION_ROOT=/private/tmp", workflow)
        self.assertIn("/opt/homebrew/opt/make/libexec/gnubin/make", workflow)
        self.assertIn("ssh-keygen -y -P ''", workflow)
        self.assertNotIn("security import", workflow)
        self.assertNotIn("crane auth", workflow)

    def test_workflow_does_not_create_a_patch_release_or_run_release_only_work(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("gh release create", workflow)
        self.assertNotIn("CodeQL", workflow)
        self.assertNotIn("make docs", workflow)
        self.assertNotIn("package-release", workflow)

    def test_recoverable_pipeline_exports_authenticated_stage_artifacts(self) -> None:
        pipeline = PIPELINE.read_text(encoding="utf-8")
        stage_module = STAGE_MODULE.read_text(encoding="utf-8")
        makefile = MAKEFILE.read_text(encoding="utf-8")
        self.assertIn("'benchmark-reconstruction'", pipeline)
        self.assertIn("'containerization-benchmark-cctl': 'bin/cctl'", pipeline)
        self.assertIn("artifact-archive-sha256", stage_module)
        self.assertIn("artifact-manifest-sha256", stage_module)
        self.assertIn('"--stageSelector=$${PIPELINE_STAGE_SELECTOR}"', makefile)
        self.assertIn("PIPELINE_ATTEMPT_ID is unsafe", makefile)


if __name__ == "__main__":
    unittest.main()
