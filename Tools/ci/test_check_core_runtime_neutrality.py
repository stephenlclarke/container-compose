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
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("check-core-runtime-neutrality.py")
SPEC = importlib.util.spec_from_file_location("check_core_runtime_neutrality", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
checker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = checker
SPEC.loader.exec_module(checker)


def package_with_dependencies(
    *dependencies: dict[str, list[object]],
    spi_dependencies: list[dict[str, list[object]]] | None = None,
) -> dict[str, object]:
    return {
        "targets": [
            {
                "name": "ComposeCore",
                "dependencies": list(dependencies),
            },
            {
                "name": "ComposeRuntimeSPI",
                "dependencies": spi_dependencies or [],
            },
        ]
    }


class CoreRuntimeNeutralityTests(unittest.TestCase):
    def test_accepts_spi_only_dependency(self) -> None:
        package = package_with_dependencies({"byName": ["ComposeRuntimeSPI", None]})

        self.assertEqual(checker.package_dependency_errors(package), [])

    def test_rejects_apple_product_dependency(self) -> None:
        package = package_with_dependencies(
            {"byName": ["ComposeRuntimeSPI", None]},
            {"product": ["ContainerResource", "container", None, None]},
        )

        self.assertEqual(
            checker.package_dependency_errors(package),
            [
                "ComposeCore dependencies must be exactly "
                "['ComposeRuntimeSPI'], found ['ComposeRuntimeSPI', 'ContainerResource']"
            ],
        )

    def test_rejects_missing_core_target(self) -> None:
        self.assertEqual(
            checker.package_dependency_errors({"targets": []}),
            [
                "expected one ComposeCore target, found 0",
                "expected one ComposeRuntimeSPI target, found 0",
            ],
        )

    def test_rejects_spi_dependencies(self) -> None:
        package = package_with_dependencies(
            {"byName": ["ComposeRuntimeSPI", None]},
            spi_dependencies=[
                {"product": ["ContainerResource", "container", None, None]},
            ],
        )

        self.assertEqual(
            checker.package_dependency_errors(package),
            [
                "ComposeRuntimeSPI dependencies must be exactly "
                "[], found ['ContainerResource']"
            ],
        )

    def test_reports_container_import_forms_with_locations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Nested").mkdir()
            (root / "Allowed.swift").write_text(
                "import ComposeRuntimeSPI\nimport Foundation\n",
                encoding="utf-8",
            )
            forbidden = root / "Nested" / "Forbidden.swift"
            forbidden.write_text(
                "import ContainerResource\n"
                "@_exported public import ContainerizationOCI\n"
                "@_implementationOnly import struct ContainerResource.ProcessConfiguration\n",
                encoding="utf-8",
            )

            self.assertEqual(
                checker.forbidden_imports(root),
                [
                    f"{forbidden}:1: forbidden Apple import ContainerResource",
                    f"{forbidden}:2: forbidden Apple import ContainerizationOCI",
                    f"{forbidden}:3: forbidden Apple import ContainerResource",
                ],
            )


if __name__ == "__main__":
    unittest.main()
