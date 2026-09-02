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

"""Tests for deterministic, source-bound VM-init OCI archives."""

import gzip
import io
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


CREATOR = Path(__file__).with_name("create-vminit-oci-archive.py")
VALIDATOR = Path(__file__).with_name("validate-oci-image-layout.py")
REFERENCES = [
    "vminit:container-compose",
    "ghcr.io/stephenlclarke/containerization/vminit:" + "a" * 40,
]


def write_rootfs(path: Path) -> None:
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w", format=tarfile.PAX_FORMAT) as archive:
        content = b"#!/bin/sh\n"
        info = tarfile.TarInfo("sbin/vminitd")
        info.mode = 0o755
        info.mtime = 0
        info.size = len(content)
        archive.addfile(info, io.BytesIO(content))
    with path.open("wb") as stream:
        with gzip.GzipFile(filename="", mode="wb", fileobj=stream, mtime=0) as compressed:
            compressed.write(payload.getvalue())


class CreateVminitOCIArchiveTests(unittest.TestCase):
    """The Current guest authority must be reproducible and exact."""

    def create(self, rootfs: Path, output: Path) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(CREATOR),
            "--rootfs",
            str(rootfs),
            "--output",
            str(output),
            "--source-url",
            "https://github.com/stephenlclarke/containerization",
        ]
        for reference in REFERENCES:
            command.extend(["--reference", reference])
        return subprocess.run(command, check=False, text=True, capture_output=True)

    def test_archive_is_deterministic_and_contains_exact_references(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rootfs = root / "init.rootfs.tar.gz"
            first = root / "first.oci.tar"
            second = root / "second.oci.tar"
            write_rootfs(rootfs)

            self.assertEqual(self.create(rootfs, first).returncode, 0)
            self.assertEqual(self.create(rootfs, second).returncode, 0)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            validation = subprocess.run(
                [sys.executable, str(VALIDATOR), str(first), *REFERENCES],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(validation.returncode, 0, validation.stderr)

    def test_validator_rejects_a_stale_containerization_reference(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rootfs = root / "init.rootfs.tar.gz"
            archive = root / "vminit.oci.tar"
            write_rootfs(rootfs)
            self.assertEqual(self.create(rootfs, archive).returncode, 0)

            stale = "ghcr.io/stephenlclarke/containerization/vminit:" + "b" * 40
            validation = subprocess.run(
                [sys.executable, str(VALIDATOR), str(archive), REFERENCES[0], stale],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(validation.returncode, 0)
            self.assertIn("missing required reference", validation.stderr)

    def test_creator_rejects_a_non_gzip_rootfs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rootfs = root / "init.rootfs.tar.gz"
            rootfs.write_bytes(b"not a compressed rootfs")
            result = self.create(rootfs, root / "vminit.oci.tar")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not a gzip-compressed tar layer", result.stderr)


if __name__ == "__main__":
    unittest.main()
