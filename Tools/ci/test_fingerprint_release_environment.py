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
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

SCRIPT = Path(__file__).with_name("fingerprint-release-environment.py")


def load_script() -> ModuleType:
    specification = importlib.util.spec_from_file_location(
        "fingerprint_release_environment", SCRIPT
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"could not load {SCRIPT}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class FingerprintReleaseEnvironmentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script()

    def test_unknown_environment_input_fails_closed(self) -> None:
        root = Path("/")
        baseline = self.module.fingerprint_environment({"PATH": "/usr/bin"}, root)
        changed = self.module.fingerprint_environment(
            {"PATH": "/usr/bin", "FUTURE_RELEASE_POLICY": "enabled"}, root
        )

        self.assertNotEqual(baseline, changed)

    def test_execution_identity_and_output_paths_do_not_invalidate_proof(self) -> None:
        root = Path("/")
        baseline = self.module.fingerprint_environment(
            {
                "PATH": "/usr/bin",
                "CONTAINER_RUNTIME_RUN_ID": "first",
                "PARITY_EVIDENCE_DIR": "/tmp/first",
                "CODEX_THREAD_ID": "first-task",
            },
            root,
        )
        changed = self.module.fingerprint_environment(
            {
                "PATH": "/usr/bin",
                "CONTAINER_RUNTIME_RUN_ID": "second",
                "PARITY_EVIDENCE_DIR": "/tmp/second",
                "CODEX_THREAD_ID": "second-task",
            },
            root,
        )

        self.assertEqual(baseline, changed)

    def test_selected_executable_content_is_part_of_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            normalizer = root / "compose normalizer"
            normalizer.write_bytes(b"first normalizer")
            environment = {
                "CONTAINER_COMPOSE_NORMALIZER": str(normalizer),
                "PATH": "/usr/bin",
            }
            initial = self.module.fingerprint_environment(environment, root)
            normalizer.write_bytes(b"second normalizer")
            changed = self.module.fingerprint_environment(environment, root)

            self.assertNotEqual(initial, changed)

    def test_manifest_never_contains_plaintext_values_or_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selected = root / "secret-named-tool"
            selected.write_bytes(b"tool contents")
            manifest = self.module.environment_manifest(
                {
                    "PATH": "/usr/bin",
                    "SENSITIVE_RELEASE_INPUT": "do-not-disclose",
                    "SELECTED_TOOL": str(selected),
                },
                root,
            )
            encoded = repr(manifest)

            self.assertNotIn("do-not-disclose", encoded)
            self.assertNotIn(str(selected), encoded)
            self.assertIn("SENSITIVE_RELEASE_INPUT", encoded)
            self.assertIn("selected_file_sha256", encoded)

    def test_non_path_values_are_hashed_without_file_probe_failures(self) -> None:
        value = "opaque-" + ("x" * 8192)

        manifest = self.module.environment_manifest(
            {"OPAQUE_RELEASE_INPUT": value, "PATH": "/usr/bin"}, Path("/")
        )

        self.assertIn("OPAQUE_RELEASE_INPUT", manifest["entries"])
        self.assertNotIn(value, repr(manifest))


if __name__ == "__main__":
    unittest.main()
