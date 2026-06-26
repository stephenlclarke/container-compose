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

"""Unit tests for the Homebrew formula release updater."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class HomebrewFormulaUpdateTests(unittest.TestCase):
    """Formula updates written by frozen branch workflows."""

    def test_update_replaces_url_checksum_version_and_asset_label(self) -> None:
        """Release updates must keep Homebrew fetchable with a real checksum."""
        with tempfile.TemporaryDirectory() as directory:
            formula = Path(directory) / "container-compose-snapshot.rb"
            formula.write_text(
                """
class ContainerComposeSnapshot < Formula
  url "https://example.invalid/old.tar.gz"
  sha256 :no_check
  version "old"

  def caveats
    <<~EOS
      This formula installs the old debug prebuilt release asset:
        old.tar.gz
    EOS
  end
end
                """.strip(),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("update-homebrew-formula.py")),
                    "--formula",
                    str(formula),
                    "--url",
                    "https://example.invalid/new.tar.gz",
                    "--version",
                    "snapshot-bootstrap-abcdef123456",
                    "--asset",
                    "new.tar.gz",
                    "--label",
                    "snapshot/bootstrap debug",
                    "--sha256",
                    "abc123",
                ],
                check=True,
            )

            self.assertEqual(
                formula.read_text(encoding="utf-8"),
                """
class ContainerComposeSnapshot < Formula
  url "https://example.invalid/new.tar.gz"
  sha256 "abc123"
  version "snapshot-bootstrap-abcdef123456"

  def caveats
    <<~EOS
      This formula installs the snapshot/bootstrap debug prebuilt release asset:
        new.tar.gz
    EOS
  end
end
                """.strip(),
            )


if __name__ == "__main__":
    unittest.main()
