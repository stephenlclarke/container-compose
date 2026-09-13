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
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("retain-local-release-assets.py")
SPEC = importlib.util.spec_from_file_location("retain_release_assets", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RetainReleaseAssetsTests(unittest.TestCase):
    def test_materialize_restores_the_complete_exact_asset_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidates = root / "candidates"
            candidates.mkdir()
            archive = candidates / "asset.tar.gz"
            checksum = candidates / "asset.tar.gz.sha256"
            archive.write_bytes(b"signed-archive")
            checksum.write_text("digest  asset.tar.gz\n", encoding="utf-8")
            os.chmod(archive, 0o750)
            retained = root / "retained"
            MODULE.retain(retained, "1.2.3", [archive, checksum])
            retained_mode = MODULE.retained_path(
                retained, "1.2.3", archive.name
            ).stat().st_mode & 0o777
            archive.write_bytes(b"rebuilt-archive")
            checksum.write_text("other  asset.tar.gz\n", encoding="utf-8")

            MODULE.materialize(retained, "1.2.3", [archive, checksum])

            self.assertEqual(archive.read_bytes(), b"signed-archive")
            self.assertEqual(
                checksum.read_text(encoding="utf-8"), "digest  asset.tar.gz\n"
            )
            self.assertEqual(archive.stat().st_mode & 0o777, retained_mode)

    def test_materialize_validates_every_source_before_replacing_any_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidates = root / "candidates"
            candidates.mkdir()
            archive = candidates / "asset.tar.gz"
            missing = candidates / "missing.sha256"
            archive.write_bytes(b"signed-archive")
            retained = root / "retained"
            MODULE.retain(retained, "1.2.3", [archive])
            archive.write_bytes(b"rebuilt-archive")
            missing.write_bytes(b"new")

            with self.assertRaisesRegex(MODULE.RetentionUnavailable, "unavailable"):
                MODULE.materialize(retained, "1.2.3", [archive, missing])

            self.assertEqual(archive.read_bytes(), b"rebuilt-archive")
            self.assertEqual(missing.read_bytes(), b"new")

    def test_materialize_rejects_a_symlink_destination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "source/asset.tar.gz"
            source.parent.mkdir()
            source.write_bytes(b"signed-archive")
            retained = root / "retained"
            MODULE.retain(retained, "1.2.3", [source])
            destination_root = root / "destination"
            destination_root.mkdir()
            destination = destination_root / source.name
            destination.symlink_to(source)

            with self.assertRaisesRegex(MODULE.RetentionError, "unsafe"):
                MODULE.materialize(retained, "1.2.3", [destination])

    def test_materialize_rejects_bytes_changed_during_staging(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            destination = root / "asset.tar.gz"
            destination.write_bytes(b"signed-archive")
            retained = root / "retained"
            MODULE.retain(retained, "1.2.3", [destination])
            destination.write_bytes(b"rebuilt-archive")

            def copy_changed_bytes(_input: object, output: object) -> None:
                output.write(b"changed-during-copy")

            with mock.patch.object(
                MODULE.shutil, "copyfileobj", side_effect=copy_changed_bytes
            ):
                with self.assertRaisesRegex(MODULE.RetentionError, "changed"):
                    MODULE.materialize(retained, "1.2.3", [destination])

            self.assertEqual(destination.read_bytes(), b"rebuilt-archive")

    def test_materialize_cli_distinguishes_an_unavailable_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            destination = root / "asset.tar.gz"
            destination.write_bytes(b"candidate")

            self.assertEqual(
                MODULE.main(
                    [
                        "materialize",
                        "--root",
                        str(root / "retained"),
                        "--version",
                        "1.2.3",
                        "--asset",
                        str(destination),
                    ]
                ),
                3,
            )

    def test_retained_asset_survives_transient_cleanup_and_is_discoverable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            transient = root / "external/download/container.tar.gz"
            transient.parent.mkdir(parents=True)
            transient.write_bytes(b"archive")
            retained = root / "local"
            MODULE.retain(retained, "1.2.3", [transient])
            shutil.rmtree(transient.parent.parent)

            restored = MODULE.retained_path(retained, "1.2.3", transient.name)
            self.assertEqual(restored.read_bytes(), b"archive")
            self.assertTrue(str(restored).startswith(str(retained.resolve())))

    def test_same_stable_name_cannot_be_replaced_with_new_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            asset = root / "asset.tar.gz"
            asset.write_bytes(b"one")
            retained = root / "retained"
            MODULE.retain(retained, "1.2.3", [asset])
            asset.write_bytes(b"two")
            with self.assertRaisesRegex(MODULE.RetentionError, "conflicts"):
                MODULE.retain(retained, "1.2.3", [asset])
            objects = list((retained / "release/artifacts/objects/sha256").glob("*/*/*"))
            self.assertEqual(len(objects), 1)

    def test_manifest_cannot_redirect_lookup_outside_retained_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            asset = root / "asset.tar.gz"
            asset.write_bytes(b"archive")
            retained = root / "retained"
            MODULE.retain(retained, "1.2.3", [asset])
            manifest_path = MODULE.manifest_path(retained, "1.2.3")
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["assets"][asset.name]["path"] = str(asset)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(MODULE.RetentionError, "invalid"):
                MODULE.retained_path(retained, "1.2.3", asset.name)

    def test_exact_candidate_repairs_missing_retained_object(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            asset = root / "asset.tar.gz"
            asset.write_bytes(b"archive")
            retained = root / "retained"
            MODULE.retain(retained, "1.2.3", [asset])
            retained_path = MODULE.retained_path(retained, "1.2.3", asset.name)
            retained_path.unlink()

            MODULE.retain(retained, "1.2.3", [asset])

            self.assertEqual(
                MODULE.retained_path(retained, "1.2.3", asset.name).read_bytes(),
                b"archive",
            )

    def test_manifest_records_bytes_installed_by_single_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            asset = root / "asset.tar.gz"
            asset.write_bytes(b"first")
            retained = root / "retained"
            original_promote = MODULE.STACK_ARTIFACT.promote

            def mutate_then_promote(source: Path, destination: Path, name: str) -> Path:
                source.write_bytes(b"second")
                return original_promote(source, destination, name)

            with mock.patch.object(
                MODULE.STACK_ARTIFACT, "promote", side_effect=mutate_then_promote
            ):
                MODULE.retain(retained, "1.2.3", [asset])

            self.assertEqual(
                MODULE.retained_path(retained, "1.2.3", asset.name).read_bytes(),
                b"second",
            )


if __name__ == "__main__":
    unittest.main()
