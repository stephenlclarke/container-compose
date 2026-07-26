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

"""Regression coverage for checked-out container dependency setup."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "ci" / "use-stack-container.sh"


class UseStackContainerTests(unittest.TestCase):
    def test_rejects_missing_container_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing_checkout = Path(temporary_directory) / "container"

            result = subprocess.run(
                [SCRIPT, missing_checkout],
                cwd=ROOT,
                capture_output=True,
                check=False,
                text=True,
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            f"container checkout is missing at {missing_checkout}",
            result.stderr,
        )

    def test_resolves_incomplete_cache_before_editing_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            checkout = temporary_root / "container"
            checkout.mkdir()
            (checkout / "Package.swift").touch()
            fake_bin = temporary_root / "bin"
            fake_bin.mkdir()
            invocation_log = temporary_root / "swift-invocations"
            resolve_marker = temporary_root / "resolved"
            fake_swift = fake_bin / "swift"
            fake_swift.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$SWIFT_INVOCATION_LOG"
if [[ "$*" == "package resolve" ]]; then
    touch "$SWIFT_RESOLVE_MARKER"
elif [[ ! -f "$SWIFT_RESOLVE_MARKER" ]]; then
    exit 91
fi
""",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "SWIFT_INVOCATION_LOG": str(invocation_log),
                    "SWIFT_RESOLVE_MARKER": str(resolve_marker),
                }
            )

            result = subprocess.run(
                [SCRIPT, checkout],
                cwd=ROOT,
                capture_output=True,
                check=False,
                env=environment,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                invocation_log.read_text(encoding="utf-8").splitlines(),
                [
                    "package resolve",
                    "package unedit container --force",
                    f"package edit container --path {checkout}",
                ],
            )


if __name__ == "__main__":
    unittest.main()
