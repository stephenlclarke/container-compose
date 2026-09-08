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

"""Tests for Compose package dependency collection."""

import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("collect-compose-package-dependencies.sh")
ARTIFACTS = {
    "compose-release-build": ".build/release/compose",
    "compose-go-validation": "Tools/compose-normalizer/compose-normalizer",
}


def sha256(path: Path) -> str:
    """Return one fixture file's SHA-256 digest."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ComposePackageDependencyCollectionTests(unittest.TestCase):
    """Only the two exact content-addressed compiler products may be packaged."""

    def write_evidence(self, root: Path, stage: str, payload: str) -> None:
        """Write one producer's authenticated evidence fixture."""
        archive = root / f"{stage}.artifacts.tar"
        archive.write_bytes(f"archive for {stage}\n".encode())
        manifest = root / f"{stage}.artifacts.tsv"
        manifest.write_text(
            "\n".join(
                (
                    "schema\t1",
                    f"stage\t{stage}",
                    "repository\tcontainer-compose",
                    f"artifact\t{ARTIFACTS[stage]}\t{'a' * 64}\t1",
                    "artifact-count\t1",
                    f"archive-sha256\t{sha256(archive)}",
                )
            )
            + "\n",
            encoding="utf-8",
        )
        (root / f"{stage}.receipt.tsv").write_text(
            "\n".join(
                (
                    "schema\t4",
                    f"stage\t{stage}",
                    "repository\tcontainer-compose",
                    "source-format\tgit-tree-archive",
                    f"source-payload-sha256\t{payload}",
                    f"stage-inputs-sha256\t{'e' * 64}",
                    f"source-execution-head\t{'f' * 40}",
                    "source-tracked-clean\ttrue",
                    "artifact-count\t1",
                    "exit\t0",
                    f"artifact-archive-sha256\t{sha256(archive)}",
                    f"artifact-manifest-sha256\t{sha256(manifest)}",
                )
            )
            + "\n",
            encoding="utf-8",
        )

    def run_collector(self, root: Path) -> subprocess.CompletedProcess[str]:
        """Run the collector in a closed-input fixture directory."""
        return subprocess.run(
            ["/bin/bash", "-p", SCRIPT, "true"],
            cwd=root,
            stdin=subprocess.DEVNULL,
            check=False,
            capture_output=True,
            text=True,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
        )

    def test_collects_exact_content_addressed_producer_evidence(self) -> None:
        """Both compiler products form one six-file dependency closure."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index, stage in enumerate(ARTIFACTS):
                self.write_evidence(root, stage, str(index + 1) * 64)

            result = self.run_collector(root)

            self.assertEqual(result.returncode, 0, result.stderr)
            collected = root / "compose-package-dependencies"
            self.assertEqual(len(list(collected.iterdir())), 6)

    def test_collects_nextflow_staged_symlink_inputs(self) -> None:
        """Nextflow stages producer files as links while outputs are regular files."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            producer = root / "producer"
            producer.mkdir()
            for index, stage in enumerate(ARTIFACTS):
                self.write_evidence(producer, stage, str(index + 1) * 64)
            for evidence in producer.iterdir():
                (root / evidence.name).symlink_to(evidence)

            result = self.run_collector(root)

            self.assertEqual(result.returncode, 0, result.stderr)
            collected = root / "compose-package-dependencies"
            self.assertEqual(len(list(collected.iterdir())), 6)
            self.assertTrue(all(path.is_file() for path in collected.iterdir()))

    def test_rejects_a_producer_without_source_content_identity(self) -> None:
        """Every product must identify the exact selected source payload."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_evidence(root, "compose-release-build", "a" * 64)
            self.write_evidence(root, "compose-go-validation", "not-a-digest")

            result = self.run_collector(root)

            self.assertNotEqual(result.returncode, 0)

    def test_rejects_a_legacy_receipt_without_closed_stage_inputs(self) -> None:
        """A cached pre-contract receipt cannot enter the package stage."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for stage in ARTIFACTS:
                self.write_evidence(root, stage, "a" * 64)
            receipt = root / "compose-release-build.receipt.tsv"
            receipt.write_text(
                receipt.read_text(encoding="utf-8").replace(
                    "schema\t4", "schema\t3", 1
                ),
                encoding="utf-8",
            )

            result = self.run_collector(root)

            self.assertNotEqual(result.returncode, 0)

    def test_rejects_a_tampered_producer_archive(self) -> None:
        """An archive changed after receipt creation is never forwarded."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for stage in ARTIFACTS:
                self.write_evidence(root, stage, "a" * 64)
            (root / "compose-release-build.artifacts.tar").write_bytes(b"tampered")

            result = self.run_collector(root)

            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
