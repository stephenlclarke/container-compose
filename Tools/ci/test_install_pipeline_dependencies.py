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

"""Tests for verified pipeline dependency installation."""

import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("install-pipeline-dependencies.py")
SPEC = importlib.util.spec_from_file_location("install_pipeline_dependencies", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {MODULE_PATH}")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class PipelineDependencyInstallationTests(unittest.TestCase):
    """Recovered products must be exact and must not overwrite source."""

    def evidence(self, root: Path) -> tuple[Path, Path]:
        """Create one valid single-file dependency closure."""
        payload = root / "payload"
        artifact = payload / ".build/release/compose"
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(b"compose")
        archive = root / "dependency.tar"
        with tarfile.open(archive, "w:") as output:
            output.add(artifact, arcname=".build/release/compose", recursive=False)
        manifest = root / "dependency.tsv"
        manifest.write_text(
            "\n".join(
                (
                    "schema\t1",
                    "artifact\t.build/release/compose\t"
                    f"{installer.sha256(artifact)}\t{artifact.stat().st_size}",
                    "artifact-count\t1",
                )
            )
            + "\n",
            encoding="utf-8",
        )
        return archive, manifest

    def test_installs_verified_dependency(self) -> None:
        """An exact archive is installed at its declared path."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, manifest = self.evidence(root)
            destination = root / "source"
            destination.mkdir()

            installer.install(
                archive_path=archive,
                manifest_path=manifest,
                destination=destination,
            )

            self.assertEqual(
                (destination / ".build/release/compose").read_bytes(), b"compose"
            )

    def test_rejects_collision_before_extraction(self) -> None:
        """A dependency cannot replace a file captured from source."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, manifest = self.evidence(root)
            destination = root / "source"
            existing = destination / ".build/release/compose"
            existing.parent.mkdir(parents=True)
            existing.write_bytes(b"source")

            with self.assertRaisesRegex(installer.DependencyError, "collides"):
                installer.install(
                    archive_path=archive,
                    manifest_path=manifest,
                    destination=destination,
                )

            self.assertEqual(existing.read_bytes(), b"source")

    def test_rejects_symlinked_parent_before_extraction(self) -> None:
        """A staged source symlink cannot redirect dependency extraction."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, manifest = self.evidence(root)
            destination = root / "source"
            destination.mkdir()
            outside = root / "outside"
            outside.mkdir()
            (destination / ".build").symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(
                installer.DependencyError, "indirect or invalid parent"
            ):
                installer.install(
                    archive_path=archive,
                    manifest_path=manifest,
                    destination=destination,
                )

            self.assertFalse((outside / "release/compose").exists())

    def test_rejects_manifest_digest_mismatch(self) -> None:
        """A false per-file digest is detected after extraction."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, manifest = self.evidence(root)
            manifest.write_text(
                manifest.read_text(encoding="utf-8").replace(
                    installer.sha256(root / "payload/.build/release/compose"), "0" * 64
                ),
                encoding="utf-8",
            )
            destination = root / "source"
            destination.mkdir()

            with self.assertRaisesRegex(installer.DependencyError, "changed"):
                installer.install(
                    archive_path=archive,
                    manifest_path=manifest,
                    destination=destination,
                )


if __name__ == "__main__":
    unittest.main()
