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

"""Tests for recovered Compose package materialization."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).with_name("materialize-pipeline-package.py")
SPEC = importlib.util.spec_from_file_location("materialize_pipeline_package", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {MODULE_PATH}")
materializer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(materializer)


class PipelinePackageMaterializationTests(unittest.TestCase):
    """Only verified exact package outputs may reach the checkout."""

    def evidence(self, root: Path, commit: str) -> tuple[Path, Path, Path]:
        """Create one valid package archive, manifest and receipt."""
        payload = root / "payload"
        for name in materializer.EXPECTED_ARTIFACTS:
            (payload / name).parent.mkdir(parents=True, exist_ok=True)
        (payload / materializer.EXPECTED_ARTIFACTS[0]).write_bytes(b"compose")
        (payload / materializer.EXPECTED_ARTIFACTS[1]).write_text(
            "[compose]\n", encoding="utf-8"
        )
        (payload / materializer.EXPECTED_ARTIFACTS[2]).write_bytes(b"normalizer")
        (payload / materializer.EXPECTED_ARTIFACTS[3]).write_bytes(b"png")
        (payload / materializer.EXPECTED_ARTIFACTS[4]).write_text(
            json.dumps({"commit": commit}) + "\n", encoding="utf-8"
        )
        plugin = payload / materializer.EXPECTED_ARTIFACTS[5]
        plugin.write_bytes(b"plugin archive")
        (payload / materializer.EXPECTED_ARTIFACTS[6]).write_text(
            f"{materializer.sha256(plugin)}  {plugin.name}\n", encoding="utf-8"
        )

        archive = root / "compose-package.artifacts.tar"
        with tarfile.open(archive, "w:") as output:
            for name in materializer.EXPECTED_ARTIFACTS:
                output.add(payload / name, arcname=name, recursive=False)
        manifest = root / "compose-package.artifacts.tsv"
        manifest_lines = [
            "schema\t1",
            "stage\tcompose-package",
            "repository\tcontainer-compose",
        ]
        for name in materializer.EXPECTED_ARTIFACTS:
            path = payload / name
            manifest_lines.append(
                f"artifact\t{name}\t{materializer.sha256(path)}\t{path.stat().st_size}"
            )
        manifest_lines.extend(
            (
                f"artifact-count\t{len(materializer.EXPECTED_ARTIFACTS)}",
                f"archive-sha256\t{materializer.sha256(archive)}",
            )
        )
        manifest.write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")
        receipt = root / "compose-package.receipt.tsv"
        receipt.write_text(
            "\n".join(
                (
                    "schema\t3",
                    "stage\tcompose-package",
                    "repository\tcontainer-compose",
                    f"source-commit\t{commit}",
                    f"artifact-archive-sha256\t{materializer.sha256(archive)}",
                    f"artifact-manifest-sha256\t{materializer.sha256(manifest)}",
                )
            )
            + "\n",
            encoding="utf-8",
        )
        return receipt, manifest, archive

    def destination(self, root: Path) -> tuple[Path, str]:
        """Create a worktree-shaped output destination."""
        destination = root / "checkout"
        destination.mkdir()
        subprocess.run(["/usr/bin/git", "init", "--quiet", destination], check=True)
        subprocess.run(
            ["/usr/bin/git", "-C", destination, "config", "user.name", "Fixture"],
            check=True,
        )
        subprocess.run(
            [
                "/usr/bin/git",
                "-C",
                destination,
                "config",
                "user.email",
                "fixture@example.invalid",
            ],
            check=True,
        )
        (destination / "README.md").write_text("fixture\n", encoding="utf-8")
        subprocess.run(
            ["/usr/bin/git", "-C", destination, "add", "README.md"], check=True
        )
        subprocess.run(
            ["/usr/bin/git", "-C", destination, "commit", "--quiet", "-m", "fixture"],
            check=True,
        )
        commit = subprocess.run(
            ["/usr/bin/git", "-C", destination, "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        return destination, commit

    def test_materializes_every_verified_output(self) -> None:
        """A valid recovered package restores the normal Make outputs."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination, commit = self.destination(root)
            receipt, manifest, archive = self.evidence(root, commit)

            materializer.materialize(
                receipt=receipt,
                manifest=manifest,
                archive=archive,
                destination=destination,
            )

            for name in materializer.EXPECTED_ARTIFACTS:
                self.assertTrue((destination / name).is_file(), name)

    def test_rejects_corruption_before_touching_existing_outputs(self) -> None:
        """Digest failure remains fail-fast and leaves the checkout unchanged."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination, commit = self.destination(root)
            receipt, manifest, archive = self.evidence(root, commit)
            existing = destination / "container-compose-plugin-release-arm64.tar.gz"
            existing.write_bytes(b"existing")
            archive.write_bytes(archive.read_bytes() + b"corrupt")

            with self.assertRaisesRegex(
                materializer.MaterializationError, "archive digest"
            ):
                materializer.materialize(
                    receipt=receipt,
                    manifest=manifest,
                    archive=archive,
                    destination=destination,
                )

            self.assertEqual(existing.read_bytes(), b"existing")
            self.assertFalse((destination / "dist").exists())

    def test_failed_replacement_restores_every_existing_output(self) -> None:
        """A mid-commit failure rolls all generated outputs back together."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination, commit = self.destination(root)
            receipt, manifest, archive = self.evidence(root, commit)
            (destination / "dist").mkdir()
            (destination / "dist/old").write_bytes(b"old dist")
            plugin = destination / materializer.OUTPUT_ROOTS[1]
            sidecar = destination / materializer.OUTPUT_ROOTS[2]
            plugin.write_bytes(b"old plugin")
            sidecar.write_bytes(b"old sidecar")
            real_replace = materializer.os.replace
            failure_injected = False

            def replace_with_failure(source, target):
                nonlocal failure_injected
                if (
                    not failure_injected
                    and Path(source).name == materializer.OUTPUT_ROOTS[1]
                    and Path(target).name == plugin.name
                ):
                    failure_injected = True
                    raise OSError("injected replacement failure")
                return real_replace(source, target)

            with mock.patch.object(
                materializer.os, "replace", side_effect=replace_with_failure
            ):
                with self.assertRaisesRegex(OSError, "injected replacement failure"):
                    materializer.materialize(
                        receipt=receipt,
                        manifest=manifest,
                        archive=archive,
                        destination=destination,
                    )

            self.assertEqual((destination / "dist/old").read_bytes(), b"old dist")
            self.assertEqual(plugin.read_bytes(), b"old plugin")
            self.assertEqual(sidecar.read_bytes(), b"old sidecar")
            self.assertFalse((destination / materializer.JOURNAL_NAME).exists())
            self.assertEqual(
                list(destination.glob(".pipeline-package-previous.*")), []
            )

    def test_next_invocation_recovers_an_interrupted_transaction(self) -> None:
        """A hard interruption cannot leave generated outputs or a dirty journal."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination, _ = self.destination(root)
            transaction = "a" * 32
            backup = destination / f".pipeline-package-previous.{transaction}"
            backup.mkdir()
            (backup / "dist").mkdir()
            (backup / "dist/old").write_bytes(b"old dist")
            (destination / "dist").mkdir()
            (destination / "dist/new").write_bytes(b"partial new dist")
            materializer.write_journal(
                destination / materializer.JOURNAL_NAME,
                {
                    "schema": 1,
                    "transaction": transaction,
                    "phase": "prepared",
                    "outputs": {
                        "dist": True,
                        materializer.OUTPUT_ROOTS[1]: False,
                        materializer.OUTPUT_ROOTS[2]: False,
                    },
                },
            )

            materializer.recover_interrupted_transaction(destination)

            self.assertEqual((destination / "dist/old").read_bytes(), b"old dist")
            self.assertFalse((destination / "dist/new").exists())
            self.assertFalse((destination / materializer.JOURNAL_NAME).exists())
            self.assertFalse(backup.exists())

    def test_next_invocation_finishes_a_committed_transaction(self) -> None:
        """A crash during backup cleanup retains the complete new package."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination, _ = self.destination(root)
            transaction = "b" * 32
            backup = destination / f".pipeline-package-previous.{transaction}"
            backup.mkdir()
            (backup / "dist").mkdir()
            (backup / "dist/old").write_bytes(b"old dist")
            (destination / "dist").mkdir()
            (destination / "dist/new").write_bytes(b"complete new dist")
            materializer.write_journal(
                destination / materializer.JOURNAL_NAME,
                {
                    "schema": 1,
                    "transaction": transaction,
                    "phase": "committed",
                    "outputs": {
                        "dist": True,
                        materializer.OUTPUT_ROOTS[1]: False,
                        materializer.OUTPUT_ROOTS[2]: False,
                    },
                },
            )

            materializer.recover_interrupted_transaction(destination)

            self.assertEqual(
                (destination / "dist/new").read_bytes(), b"complete new dist"
            )
            self.assertFalse((destination / materializer.JOURNAL_NAME).exists())
            self.assertFalse(backup.exists())


if __name__ == "__main__":
    unittest.main()
