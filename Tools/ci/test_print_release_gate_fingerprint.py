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

"""Focused tests for release and per-stage parity fingerprints."""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("print-release-gate-fingerprint.py")
SPEC = importlib.util.spec_from_file_location("print_release_gate_fingerprint", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ParityScopedFingerprintTests(unittest.TestCase):
    def create_repository(self, root: pathlib.Path) -> None:
        (root / "Tools/ci").mkdir(parents=True)
        (root / "Tools/parity").mkdir(parents=True)
        (root / "Makefile").write_text("checkpoint-controller\n", encoding="utf-8")
        for name in (
            "fingerprint-release-environment.py",
            "print-release-gate-fingerprint.py",
            "run-release-checkpoint.py",
        ):
            (root / "Tools/ci" / name).write_text(name, encoding="utf-8")
        (root / "Tools/parity/check-compose-target.sh").write_text(
            "target harness\n",
            encoding="utf-8",
        )
        (root / "Tools/parity/check-compose-target.sh").chmod(0o755)
        (root / "Tools/parity/check-compose-unrelated.sh").write_text(
            "unrelated harness\n",
            encoding="utf-8",
        )

    def fingerprint(
        self,
        root: pathlib.Path,
        compose_tree: str = "complete-tree",
    ) -> str:
        return MODULE.parity_scoped_static_fingerprint(
            f"compose={compose_tree}:builder=fixture",
            {
                "RELEASE_GATE_PARITY_STAGE": "docker-compose-target-parity",
                "RELEASE_GATE_PARITY_COMPOSE_BINARY": str(root / "compose"),
            },
            root,
        )

    def test_unrelated_harness_change_preserves_stage_fingerprint(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            self.create_repository(root)
            (root / "compose").write_bytes(b"release binary")
            (root / "compose").chmod(0o755)
            original = self.fingerprint(root)

            (root / "Tools/parity/check-compose-unrelated.sh").write_text(
                "changed unrelated harness\n",
                encoding="utf-8",
            )

            self.assertEqual(
                self.fingerprint(root, compose_tree="changed-tree"),
                original,
            )

    def test_binary_and_selected_harness_changes_invalidate_stage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            self.create_repository(root)
            binary = root / "compose"
            binary.write_bytes(b"release binary")
            binary.chmod(0o755)
            original = self.fingerprint(root)

            binary.write_bytes(b"changed release binary")
            changed_binary = self.fingerprint(root)
            self.assertNotEqual(changed_binary, original)

            binary.write_bytes(b"release binary")
            (root / "Tools/parity/check-compose-target.sh").write_text(
                "changed target harness\n",
                encoding="utf-8",
            )
            self.assertNotEqual(self.fingerprint(root), original)

    def test_malformed_or_incomplete_stage_inputs_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            self.create_repository(root)
            (root / "compose").write_bytes(b"release binary")
            (root / "compose").chmod(0o755)

            with self.assertRaisesRegex(ValueError, "must be provided together"):
                MODULE.parity_scoped_static_fingerprint(
                    "compose=complete-tree:builder=fixture",
                    {"RELEASE_GATE_PARITY_STAGE": "docker-compose-target-parity"},
                    root,
                )
            with self.assertRaisesRegex(ValueError, "invalid parity checkpoint stage"):
                MODULE.parity_scoped_static_fingerprint(
                    "compose=complete-tree:builder=fixture",
                    {
                        "RELEASE_GATE_PARITY_STAGE": "target",
                        "RELEASE_GATE_PARITY_COMPOSE_BINARY": str(root / "compose"),
                    },
                    root,
                )

    def test_non_parity_fingerprint_remains_conservative(self) -> None:
        static = "compose=complete-tree:builder=fixture"

        self.assertEqual(
            MODULE.parity_scoped_static_fingerprint(static, {}),
            static,
        )


if __name__ == "__main__":
    unittest.main()
