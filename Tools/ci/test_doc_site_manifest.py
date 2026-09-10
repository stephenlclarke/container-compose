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
import io
import tarfile
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("doc-site-manifest.py")
SPEC = importlib.util.spec_from_file_location("doc_site_manifest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DocSiteManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "documentation/module").mkdir(parents=True)
        (self.root / "index.html").write_text("index", encoding="utf-8")
        (self.root / "theme-settings.json").write_text("{}", encoding="utf-8")
        (self.root / "documentation/module/index.html").write_text(
            "module", encoding="utf-8"
        )

    def test_complete_site_round_trips(self) -> None:
        MODULE.create(self.root)
        MODULE.verify(self.root)

    def test_complete_site_archive_round_trips_without_extraction(self) -> None:
        MODULE.create(self.root)
        archive = self.root.parent / "site.tgz"
        with tarfile.open(archive, "w:gz") as bundle:
            for path in self.root.rglob("*"):
                bundle.add(
                    path,
                    arcname=f"./{path.relative_to(self.root)}",
                    recursive=False,
                )
        MODULE.verify_archive(archive)

    def test_changed_or_missing_payload_is_rejected(self) -> None:
        MODULE.create(self.root)
        (self.root / "documentation/module/index.html").unlink()
        with self.assertRaisesRegex(MODULE.ManifestError, "does not match"):
            MODULE.verify(self.root)

    def test_site_without_documentation_payload_is_rejected(self) -> None:
        (self.root / "documentation/module/index.html").unlink()
        with self.assertRaisesRegex(MODULE.ManifestError, "no documentation payload"):
            MODULE.create(self.root)

    def test_symlink_is_rejected(self) -> None:
        (self.root / "documentation/link").symlink_to(self.root / "index.html")
        with self.assertRaisesRegex(MODULE.ManifestError, "symbolic link"):
            MODULE.create(self.root)

    def test_archive_path_traversal_is_rejected(self) -> None:
        archive = self.root.parent / "unsafe.tgz"
        with tarfile.open(archive, "w:gz") as bundle:
            payload = b"unsafe"
            member = tarfile.TarInfo("../outside")
            member.size = len(payload)
            bundle.addfile(member, io.BytesIO(payload))
        with self.assertRaisesRegex(MODULE.ManifestError, "unsafe"):
            MODULE.verify_archive(archive)


if __name__ == "__main__":
    unittest.main()
