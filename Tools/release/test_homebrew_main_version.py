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

"""Unit tests for Homebrew main-lane version formatting."""

import importlib.util
import unittest
from pathlib import Path


def load_module():
    module_path = Path(__file__).with_name("homebrew-main-version.py")
    spec = importlib.util.spec_from_file_location("homebrew_main_version", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HomebrewMainVersionTests(unittest.TestCase):
    """Main-lane formula versions must upgrade cleanly from stable releases."""

    def test_main_version_starts_with_plugin_semver_and_monotonic_run_number(self) -> None:
        module = load_module()

        self.assertEqual(
            module.homebrew_main_version(
                "0.6.0",
                "28518588455",
                "425F66E8F9B5C74F1D3EE05678ED5E49C6BB3DC2",
            ),
            "0.6.0-main.28518588455.425f66e8f9b5",
        )

    def test_invalid_inputs_are_rejected(self) -> None:
        module = load_module()

        with self.assertRaises(ValueError):
            module.homebrew_main_version("main-release", "28518588455", "425f66e8f9b5")
        with self.assertRaises(ValueError):
            module.homebrew_main_version("0.6.0", "0", "425f66e8f9b5")
        with self.assertRaises(ValueError):
            module.homebrew_main_version("0.6.0", "28518588455", "not-a-sha")


if __name__ == "__main__":
    unittest.main()
