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
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("check-stack-consistency.py")
SPEC = importlib.util.spec_from_file_location("check_stack_consistency", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

CONTAINERIZATION_REF = "41252f26870bc875ea0b3e97e1bb656456f02288"
BUILDER_DIGEST = "sha256:e4a1294b27c9602c3b7b26b1af753cbe5b688d91f1880e5990ed45ce5c711cc9"


def write_stack_refs(path: Path, containerization_ref: str = CONTAINERIZATION_REF) -> None:
    path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "components": {
                    "container-builder-shim": {
                        "repository": "stephenlclarke/container-builder-shim",
                        "ref": "builder-ref",
                        "image": {
                            "repository": "ghcr.io/stephenlclarke/container-builder-shim/builder",
                            "tag": "0.13.8",
                            "digest": BUILDER_DIGEST,
                        },
                    },
                    "containerization": {
                        "repository": "stephenlclarke/containerization",
                        "ref": containerization_ref,
                    },
                },
            }
        ),
        encoding="utf-8",
    )


def write_package(path: Path, requirement: str, value: str) -> None:
    path.write_text(
        textwrap.dedent(
            f"""
            import PackageDescription

            let builderShimRepository = ProcessInfo.processInfo.environment["BUILDER_SHIM_REPOSITORY"] ?? "ghcr.io/stephenlclarke/container-builder-shim/builder"
            let builderShimVersion = ProcessInfo.processInfo.environment["BUILDER_SHIM_VERSION"] ?? "0.13.8"
            let builderShimDigest = ProcessInfo.processInfo.environment["BUILDER_SHIM_DIGEST"] ?? "{BUILDER_DIGEST}"

            let package = Package(
                name: "fixture",
                dependencies: [
                    .package(
                        url: "https://github.com/stephenlclarke/containerization.git",
                        {requirement}: "{value}"
                    ),
                ]
            )
            """
        ).strip()
        + "\n",
        encoding="utf-8",
    )


def write_resolved(path: Path, revision: str = CONTAINERIZATION_REF, branch: str | None = None) -> None:
    state = {"revision": revision}
    if branch is not None:
        state["branch"] = branch
    path.write_text(
        json.dumps(
            {
                "pins": [
                    {
                        "identity": "containerization",
                        "kind": "remoteSourceControl",
                        "location": "https://github.com/stephenlclarke/containerization.git",
                        "state": state,
                    }
                ]
            }
        ),
        encoding="utf-8",
    )


class StackConsistencyTests(unittest.TestCase):
    def run_checker(self, root: Path) -> int:
        with mock.patch.object(checker, "STACK_REFS", root / "stack-refs.json"), mock.patch.object(
            checker, "CONTAINER_PACKAGE", root / "container" / "Package.swift"
        ), mock.patch.object(
            checker,
            "PACKAGE_SWIFT_FILES",
            [root / "compose" / "Package.swift", root / "container" / "Package.swift"],
        ), mock.patch.object(
            checker,
            "PACKAGE_RESOLVED_FILES",
            [root / "compose" / "Package.resolved", root / "container" / "Package.resolved"],
        ):
            return checker.main()

    def test_accepts_revision_manifest_and_lockfile_pins(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "compose").mkdir()
            (root / "container").mkdir()
            write_stack_refs(root / "stack-refs.json")
            write_package(root / "compose" / "Package.swift", "revision", CONTAINERIZATION_REF)
            write_package(root / "container" / "Package.swift", "revision", CONTAINERIZATION_REF)
            write_resolved(root / "compose" / "Package.resolved")
            write_resolved(root / "container" / "Package.resolved")

            self.assertEqual(self.run_checker(root), 0)

    def test_rejects_branch_manifest_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "compose").mkdir()
            (root / "container").mkdir()
            write_stack_refs(root / "stack-refs.json")
            write_package(root / "compose" / "Package.swift", "branch", "main")
            write_package(root / "container" / "Package.swift", "revision", CONTAINERIZATION_REF)
            write_resolved(root / "compose" / "Package.resolved")
            write_resolved(root / "container" / "Package.resolved")

            with self.assertRaisesRegex(SystemExit, "must use revision"):
                self.run_checker(root)

    def test_rejects_lockfile_revision_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "compose").mkdir()
            (root / "container").mkdir()
            write_stack_refs(root / "stack-refs.json")
            write_package(root / "compose" / "Package.swift", "revision", CONTAINERIZATION_REF)
            write_package(root / "container" / "Package.swift", "revision", CONTAINERIZATION_REF)
            write_resolved(root / "compose" / "Package.resolved", "wrong-ref")
            write_resolved(root / "container" / "Package.resolved")

            with self.assertRaisesRegex(SystemExit, "revision mismatch"):
                self.run_checker(root)

    def test_rejects_lockfile_branch_pin(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "compose").mkdir()
            (root / "container").mkdir()
            write_stack_refs(root / "stack-refs.json")
            write_package(root / "compose" / "Package.swift", "revision", CONTAINERIZATION_REF)
            write_package(root / "container" / "Package.swift", "revision", CONTAINERIZATION_REF)
            write_resolved(root / "compose" / "Package.resolved", branch="main")
            write_resolved(root / "container" / "Package.resolved")

            with self.assertRaisesRegex(SystemExit, "must not include a branch"):
                self.run_checker(root)


if __name__ == "__main__":
    unittest.main()
