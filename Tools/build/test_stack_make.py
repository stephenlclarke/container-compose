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

"""Execution proof for Make-level stack pin recovery."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = REPOSITORY_ROOT / "Makefile"
PIN_TOOL = REPOSITORY_ROOT / "Tools/build/stack-pin.py"


class StackMakeRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        self.log = self.root / "build.log"
        self.fail = self.root / "fail-container"
        self.containerization = self.create_repository("containerization")
        self.engine = self.create_repository("container-engine-api")
        self.container = self.create_repository("container")
        self.swift = self.root / "fake-swift"
        self.swift.write_text(
            """#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'Swift version 6.2 (fixture)\n'
  exit 0
fi
scratch=
configuration=debug
product=
show=0
while (($#)); do
  case "$1" in
    --scratch-path) scratch=$2; shift 2 ;;
    -c) configuration=$2; shift 2 ;;
    --product) product=$2; shift 2 ;;
    --show-bin-path) show=1; shift ;;
    *) shift ;;
  esac
done
bin_path="${scratch}/${configuration}"
if ((show)); then
  printf '%s\n' "${bin_path}"
  exit 0
fi
printf 'build:%s\n' "${product}" >> "${STACK_TEST_LOG}"
if [[ "${product}" == container && -f "${STACK_TEST_FAIL}" ]]; then
  mv "${STACK_TEST_FAIL}" "${STACK_TEST_FAIL}.consumed"
  exit 19
fi
mkdir -p "${bin_path}"
printf 'artifact:%s\n' "${product}" > "${bin_path}/${product}"
""",
            encoding="utf-8",
        )
        self.swift.chmod(0o755)

    def git(self, repository: Path, *arguments: str) -> str:
        result = subprocess.run(
            ["/usr/bin/git", "-C", str(repository), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        )
        return result.stdout.strip()

    def create_repository(self, name: str) -> Path:
        repository = self.root / name
        repository.mkdir()
        self.git(repository, "init", "-q")
        self.git(repository, "config", "user.name", "Test")
        self.git(repository, "config", "user.email", "test@example.invalid")
        (repository / "source.txt").write_text("source\n", encoding="utf-8")
        self.git(repository, "add", "source.txt")
        self.git(repository, "commit", "-q", "-m", "test: create fixture")
        return repository

    def run_build(self) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "STACK_TEST_FAIL": str(self.fail),
                "STACK_TEST_LOG": str(self.log),
            }
        )
        return subprocess.run(
            [
                "/usr/bin/make",
                "-f",
                str(MAKEFILE),
                "stack-container-build",
                f"STACK_STATE_ROOT={self.state}",
                f"STACK_PIN_TOOL={PIN_TOOL}",
                f"STACK_SWIFT={self.swift}",
                f"STACK_SWIFT_CONTRACT={'a' * 64}",
                "STACK_LOCK_HELD=1",
                "PYTHON=/opt/homebrew/bin/python3.12",
                f"CONTAINERIZATION_STACK_REPO={self.containerization}",
                f"CONTAINER_ENGINE_API_STACK_REPO={self.engine}",
                f"CONTAINER_STACK_REPO={self.container}",
            ],
            cwd=self.root,
            env=environment,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def logged_builds(self) -> list[str]:
        if not self.log.exists():
            return []
        return self.log.read_text(encoding="utf-8").splitlines()

    def test_state_initialization_refuses_to_claim_unmarked_data(self) -> None:
        self.state.mkdir()
        (self.state / "unrelated.txt").write_text("preserve\n", encoding="utf-8")
        result = subprocess.run(
            [
                "/usr/bin/make",
                "-f",
                str(MAKEFILE),
                "stack-state-init",
                f"STACK_STATE_ROOT={self.state}",
            ],
            cwd=self.root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-empty unmarked", result.stderr)
        self.assertEqual(
            (self.state / "unrelated.txt").read_text(encoding="utf-8"),
            "preserve\n",
        )
        self.assertFalse((self.state / ".container-compose-build-root").exists())

    def test_retry_reuses_successful_upstream_pins_after_failure(self) -> None:
        self.fail.write_text("fail once\n", encoding="utf-8")
        failed = self.run_build()
        self.assertEqual(failed.returncode, 2, failed.stderr)
        self.assertTrue((self.state / "pins/debug/containerization.json").is_file())
        self.assertTrue((self.state / "pins/debug/container-engine-api.json").is_file())
        self.assertFalse((self.state / "pins/debug/container.json").exists())

        resumed = self.run_build()
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertEqual(
            self.logged_builds(),
            ["build:cctl", "build:container-engine", "build:container", "build:container"],
        )
        self.assertTrue((self.state / "pins/debug/container.json").is_file())

    def test_changed_upstream_rebuilds_only_its_transitive_path(self) -> None:
        first = self.run_build()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.log.unlink()

        (self.containerization / "source.txt").write_text(
            "changed\n", encoding="utf-8"
        )
        self.git(self.containerization, "add", "source.txt")
        self.git(
            self.containerization,
            "commit",
            "-q",
            "-m",
            "test: change fixture",
        )
        rebuilt = self.run_build()
        self.assertEqual(rebuilt.returncode, 0, rebuilt.stderr)
        self.assertEqual(self.logged_builds(), ["build:cctl", "build:container"])


if __name__ == "__main__":
    unittest.main()
