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
import shutil
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("retain-local-release-assets.py")
SPEC = importlib.util.spec_from_file_location("retain_release_assets", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RetainReleaseAssetsTests(unittest.TestCase):
    def test_retained_asset_survives_transient_cleanup_and_is_discoverable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
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
            root = Path(directory)
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
            root = Path(directory)
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


if __name__ == "__main__":
    unittest.main()
