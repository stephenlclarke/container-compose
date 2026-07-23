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

"""Unit tests for relocatable release checksum sidecars."""

import hashlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


WRITER = Path(__file__).with_name("write-sha256-sidecar.py")


class SHA256SidecarWriterTests(unittest.TestCase):
    """Release checksums must remain valid outside the build runner."""

    def test_writer_uses_only_the_asset_basename(self) -> None:
        """Runner paths must not leak into the published checksum record."""
        with tempfile.TemporaryDirectory() as directory:
            asset = Path(directory) / "runner" / "_work" / "_temp" / "package.tar.gz"
            asset.parent.mkdir(parents=True)
            asset.write_bytes(b"portable release bytes\n" * 8192)

            subprocess.run([sys.executable, str(WRITER), str(asset)], check=True)

            expected = hashlib.sha256(asset.read_bytes()).hexdigest()
            self.assertEqual(
                asset.with_name(f"{asset.name}.sha256").read_text(encoding="utf-8"),
                f"{expected}  {asset.name}\n",
            )

    def test_downloaded_asset_passes_shasum_check(self) -> None:
        """The published pair should verify after both files are relocated."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            asset = root / "runner" / "_work" / "_temp" / "package.tar.gz"
            asset.parent.mkdir(parents=True)
            asset.write_bytes(b"downloaded release bytes\n")
            subprocess.run([sys.executable, str(WRITER), str(asset)], check=True)

            download = root / "download"
            download.mkdir()
            shutil.copy2(asset, download / asset.name)
            shutil.copy2(
                asset.with_name(f"{asset.name}.sha256"),
                download / f"{asset.name}.sha256",
            )

            result = subprocess.run(
                ["shasum", "-a", "256", "-c", f"{asset.name}.sha256"],
                cwd=download,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f"{asset.name}: OK\n")


if __name__ == "__main__":
    unittest.main()
