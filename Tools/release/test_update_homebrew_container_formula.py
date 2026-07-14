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

"""Unit tests for the Compose-owned container formula renderer."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


UPDATER = Path(__file__).with_name("update-homebrew-container-formula.py")
TEMPLATE = """class Container < Formula
  url "https://example.invalid/container.tar.gz"
  version "main-release.1"
  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  def post_install
    compose_plugin = HOMEBREW_PREFIX/"opt/container-compose/libexec/container-plugins/compose"
  end

  def caveats
    <<~EOS
      This formula installs the main lane prebuilt package asset:
        container-homebrew-main-release-arm64.tar.gz

      If stephenlclarke/tap/container-compose is installed, this formula links
      the Compose plugin into:
        #{opt_prefix}/libexec/container-plugins/compose
    EOS
  end
end
"""


class UpdateHomebrewContainerFormulaTests(unittest.TestCase):
    """The runtime formula must link the matching Compose lane."""

    def render(self, directory: Path, compose_formula: str, formula_class: str) -> Path:
        template = directory / "container.rb.in"
        formula = directory / "container.rb"
        template.write_text(TEMPLATE, encoding="utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(UPDATER),
                "--formula",
                str(formula),
                "--template",
                str(template),
                "--formula-class",
                formula_class,
                "--compose-formula",
                compose_formula,
                "--url",
                "https://github.com/stephenlclarke/container-compose/releases/download/0.6.70/container-release-arm64.tar.gz",
                "--sha256",
                "b" * 64,
                "--version",
                "0.6.70",
                "--label",
                "stable release",
                "--asset",
                "container-release-arm64.tar.gz",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return formula

    def test_stable_formula_uses_the_stable_compose_plugin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            formula = self.render(Path(directory), "container-compose", "Container")
            rendered = formula.read_text(encoding="utf-8")

            subprocess.run(["ruby", "-c", str(formula)], check=True)
            self.assertIn("class Container < Formula", rendered)
            self.assertIn(
                "releases/download/0.6.70/container-release-arm64.tar.gz",
                rendered,
            )
            self.assertIn('version "0.6.70"', rendered)
            self.assertIn('sha256 "' + "b" * 64 + '"', rendered)
            self.assertIn("stephenlclarke/tap/container-compose", rendered)
            self.assertIn("opt/container-compose/libexec/container-plugins/compose", rendered)
            self.assertIn(
                "This formula installs the stable release prebuilt package asset:",
                rendered,
            )
            self.assertIn("container-release-arm64.tar.gz", rendered)

    def test_current_formula_uses_the_current_compose_plugin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            formula = self.render(Path(directory), "container-compose-current", "ContainerCurrent")
            rendered = formula.read_text(encoding="utf-8")

            subprocess.run(["ruby", "-c", str(formula)], check=True)
            self.assertIn("class ContainerCurrent < Formula", rendered)
            self.assertIn("stephenlclarke/tap/container-compose-current", rendered)
            self.assertIn(
                "opt/container-compose-current/libexec/container-plugins/compose",
                rendered,
            )

    def test_unknown_compose_formula_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            template = path / "container.rb.in"
            template.write_text(TEMPLATE, encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(UPDATER),
                    "--formula",
                    str(path / "container.rb"),
                    "--template",
                    str(template),
                    "--formula-class",
                    "Container",
                    "--compose-formula",
                    "container-compose-preview",
                    "--url",
                    "https://example.invalid/container.tar.gz",
                    "--sha256",
                    "b" * 64,
                    "--version",
                    "0.6.70",
                    "--label",
                    "stable release",
                    "--asset",
                    "container-release-arm64.tar.gz",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("compose formula must be one of", completed.stderr)


if __name__ == "__main__":
    unittest.main()
