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
        older = self.run_record(
            databaseId=self.run_id - 1,
            createdAt="2026-08-23T14:32:14Z",
            url=(
                "https://github.com/stephenlclarke/containerization/"
                f"actions/runs/{self.run_id - 1}"
            ),
        )
        resolved = MODULE.resolve_containerization_run(
            [older, self.run_record(), self.run_record(headSha="b" * 40)],
            self.revision,
        )
        self.assertEqual(resolved["runId"], self.run_id)
        self.assertEqual(resolved["containerizationRef"], self.revision)
        self.assertEqual(
            [
                candidate["runId"]
                for candidate in MODULE.containerization_run_candidates(
                    [older, self.run_record()], self.revision
                )
            ],
            [self.run_id, self.run_id - 1],
        )

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
            manifest_digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
            receipt = root / "containerization-benchmark-cctl.receipt.tsv"
            receipt.write_text(
                "schema\t3\n"
                "stage\tcontainerization-benchmark-cctl\n"
                "repository\tcontainerization\n"
                f"source-payload-sha256\t{'1' * 64}\n"
                f"source-metadata-sha256\t{'2' * 64}\n"
                f"command-sha256\t{'3' * 64}\n"
                f"stage-tools-sha256\t{'4' * 64}\n"
                f"artifact-archive-sha256\t{archive_digest}\n"
                f"artifact-manifest-sha256\t{manifest_digest}\n"
                "artifact-count\t1\n"
                "exit\t0\n",
                encoding="utf-8",
            )
            receipt_digest = hashlib.sha256(receipt.read_bytes()).hexdigest()
            summary = root / "pipeline-summary.tsv"
            summary.write_text(
                "schema\t1\n"
                "stage-receipt\t"
                f"{receipt.name}\t{receipt_digest}\n"
                "stage-artifact\t"
                f"{archive.name}\t{archive_digest}\n"
                "stage-artifact\t"
                f"{manifest.name}\t{manifest_digest}\n"
                "complete\ttrue\n",
                encoding="utf-8",
            )
            output = root / "prepared/cctl"
            result = MODULE.extract_cctl(
                archive, manifest, receipt, summary, output
            )
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(result["cctlArtifactSha256"], archive_digest)
            self.assertEqual(result["cctlReceiptSha256"], receipt_digest)

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
        self.assertIn("package-run-candidates", workflow)
        self.assertIn("no retained complete package run exists", workflow)
        self.assertIn("gh api --paginate --slurp", workflow)
        self.assertNotIn("--workflow prebuilt-binaries.yml --limit", workflow)
        self.assertNotIn("--limit ", workflow)
        self.assertIn("verify-developer-id-archive.sh", workflow)
        self.assertIn("validate-initfs", workflow)
        self.assertIn("run-candidates", workflow)
        self.assertIn("no retained initfs run exists", workflow)
        self.assertIn("artifactDigest", workflow)
        self.assertIn("PIPELINE_PROFILE=benchmark-reconstruction", workflow)
        self.assertIn("containerization-benchmark-cctl", workflow)
        self.assertIn("validate-oci-image-layout.py", workflow)
        self.assertIn("actions: write", workflow)
        self.assertIn('-f documentation_pr="${pr_number}"', workflow)

    def test_workflow_retries_artifact_transfers_atomically(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("download_run_artifact()", workflow)
        self.assertIn("download_api_artifact()", workflow)
        self.assertIn("for attempt in 1 2 3", workflow)
        self.assertIn("run-artifact.XXXXXX", workflow)
        self.assertIn('sidecar="${artifact}.sha256"', workflow)
        self.assertIn('[[ -s "${attempt_root}/${sidecar}" ]]', workflow)
        sidecar_publish = workflow.index(
            'mv "${attempt_root}/${sidecar}" "${target_sidecar}"'
        )
        archive_publish = workflow.index(
            'mv "${attempt_root}/${artifact}" "${target}"'
        )
        self.assertLess(sidecar_publish, archive_publish)
        self.assertIn('mv "${attempt_root}/${artifact}" "${target}"', workflow)
        self.assertIn('partial="${output}.partial.${attempt}"', workflow)
        self.assertIn('mv "${partial}" "${output}"', workflow)
        self.assertIn("extract-initfs --archive", workflow)
        self.assertIn('--digest "${initfs_artifact_digest}"', workflow)

    def test_workflow_keeps_runtime_inputs_local_and_noninteractive(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('"${RUNNER_TEMP}" "${GITHUB_RUN_ID}"', workflow)
        self.assertIn("PIPELINE_STATE_ROOT: /Volumes/SSD/github/", workflow)
        self.assertIn("PARITY_INCLUDE_REMOTE_LOGGING=0", workflow)
        self.assertIn("CONTAINER_RUNTIME_LOCAL_EXECUTION_ROOT=/private/tmp", workflow)
        self.assertIn("/opt/homebrew/opt/make/libexec/gnubin/make", workflow)
        self.assertIn("ssh-keygen -y -P ''", workflow)
        self.assertNotIn("security import", workflow)
        self.assertNotIn("crane auth", workflow)

    def test_workflow_preloads_a_pinned_fixture_without_registry_access(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        makefile = MAKEFILE.read_text(encoding="utf-8")
        prepare = workflow.index("Prepare pinned offline fixture image")
        quiet_host = workflow.index("Require a quiet benchmark host")

        self.assertLess(prepare, quiet_host)
        self.assertIn("FIXTURE_IMAGE_INDEX_DIGEST: sha256:", workflow)
        self.assertIn(
            "FIXTURE_IMAGE_MANIFEST_DIGEST: "
            "sha256:5c2987750228f21fa5e602dbc36c4535b34deed426b8f13806c0e2dfbf9b1fba",
            workflow,
        )
        self.assertIn(
            "FIXTURE_IMAGE_MANIFEST_MEDIA_TYPE: "
            "application/vnd.oci.image.manifest.v1+json",
            workflow,
        )
        self.assertIn("docker-daemon:${FIXTURE_IMAGE}", workflow)
        self.assertIn(
            'if ! docker image inspect "${FIXTURE_IMAGE}" > "${docker_metadata}"; then',
            workflow,
        )
        self.assertIn("docker pull ${expected_reference}", workflow)
        self.assertIn(
            "docker image tag ${expected_reference} ${FIXTURE_IMAGE}", workflow
        )
        self.assertNotIn(
            "recover before retrying with: docker pull %s", workflow
        )
        self.assertIn("skopeo copy --format oci", workflow)
        self.assertNotIn("--preserve-digests", workflow)
        self.assertIn("--src-daemon-host", workflow)
        self.assertIn("docker context inspect", workflow)
        self.assertIn("expected exactly one manifest", workflow)
        self.assertIn(
            '[[ "${archive_media_type}" == "${FIXTURE_IMAGE_MANIFEST_MEDIA_TYPE}" ]]',
            workflow,
        )
        self.assertIn("validate-oci-image-layout.py", workflow)
        self.assertIn("PARITY_FIXTURE_IMAGE_ARCHIVE=", workflow)
        self.assertIn("PARITY_FIXTURE_IMAGE_ARCHIVE_REFERENCE=3.20", workflow)
        self.assertIn(
            'PARITY_FIXTURE_IMAGE_ARCHIVE="${PARITY_FIXTURE_IMAGE_ARCHIVE}"',
            workflow,
        )
        self.assertIn(
            'PARITY_FIXTURE_IMAGE_ARCHIVE="$(PARITY_FIXTURE_IMAGE_ARCHIVE)"',
            makefile,
        )
        self.assertIn(
            "PARITY_FIXTURE_IMAGE_ARCHIVE_REFERENCE=\"$(PARITY_FIXTURE_IMAGE_ARCHIVE_REFERENCE)\"",
            makefile,
        )

    def test_workflow_checkpoints_fixture_groups_before_finalizing(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('"lifecycle,logging-stream"', workflow)
        self.assertIn('"logging-file"', workflow)
        self.assertIn('"logging-read,logging-aggregate"', workflow)
        self.assertIn('PARITY_EVIDENCE_MODE="${evidence_mode}"', workflow)
        self.assertIn("PARITY_FINALIZE_EVIDENCE=0", workflow)
        self.assertIn("--finalize-only", workflow)
        self.assertIn("if: inputs.fixture_groups == 'all'", workflow)
        self.assertIn(
            'runtime_root="${RUNTIME_ROOT_PREFIX}-${version}-p${phase_index}"',
            workflow,
        )
        self.assertNotIn('${version}-${phase//,/-}', workflow)

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
