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

import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = REPOSITORY_ROOT / "Makefile"
PIN_TOOL = REPOSITORY_ROOT / "Tools/build/stack-pin.py"
ARTIFACT_TOOL = REPOSITORY_ROOT / "Tools/build/stack-artifact.py"
DEADLINE_TOOL = REPOSITORY_ROOT / "Tools/ci/run-command-with-deadline.py"


class StackMakeRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.retained = self.root / "local-retained"
        self.transient = self.root / "external-transient"
        self.log = self.root / "build.log"
        self.fail = self.root / "fail-container"
        self.containerization = self.create_repository("containerization")
        self.engine = self.create_repository("container-engine-api")
        self.container = self.create_repository("container")
        self.builder = self.create_repository("container-builder-shim")
        self.compose = self.create_repository("container-compose")
        (self.compose / "Makefile").symlink_to(MAKEFILE)
        (self.compose / "Package.resolved").write_text(
            '{"pins":[]}\n', encoding="utf-8"
        )
        self.git(self.compose, "add", "Makefile", "Package.resolved")
        self.git(self.compose, "commit", "-q", "-m", "test: add lockfile")
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
        self.go = self.root / "fake-go"
        self.go.write_text(
            """#!/bin/bash
set -euo pipefail
output=
while (($#)); do
  case "$1" in
    -o) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "${output}" ]]
printf 'build:container-builder-shim\n' >> "${STACK_TEST_LOG}"
mkdir -p "$(dirname "${output}")"
printf 'artifact:container-builder-shim\n' > "${output}"
""",
            encoding="utf-8",
        )
        self.go.chmod(0o755)
        self.stack_wrapper = self.root / "fake-stack-wrapper"
        self.stack_wrapper.write_text(
            """#!/usr/bin/env python3
import os
import sys

try:
    separator = sys.argv.index("--")
except ValueError:
    print("fake stack wrapper received no command", file=sys.stderr)
    raise SystemExit(2)
os.execvp(sys.argv[separator + 1], sys.argv[separator + 1:])
""",
            encoding="utf-8",
        )
        self.stack_wrapper.chmod(0o755)
        self.lock = self.root / "fake-lockf"
        self.lock.write_text(
            """#!/bin/bash
set -euo pipefail
[[ "${1:-}" == -t && "${2:-}" == 0 && -n "${3:-}" ]]
shift 3
exec "$@"
""",
            encoding="utf-8",
        )
        self.lock.chmod(0o755)

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
                f"STACK_RETAINED_ROOT={self.retained}",
                f"STACK_TRANSIENT_ROOT={self.transient}",
                "STACK_REQUIRE_SEPARATE_FILESYSTEMS=0",
                f"STACK_PIN_TOOL={PIN_TOOL}",
                f"STACK_ARTIFACT_TOOL={ARTIFACT_TOOL}",
                f"STACK_DEADLINE_TOOL={DEADLINE_TOOL}",
                f"STACK_SWIFT={self.swift}",
                f"STACK_SWIFT_CONTRACT={'a' * 64}",
                "STACK_LOCK_HELD=1",
                f"PYTHON={sys.executable}",
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

    def run_full_build(self) -> subprocess.CompletedProcess[str]:
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
                "stack-build",
                f"STACK_RETAINED_ROOT={self.retained}",
                f"STACK_TRANSIENT_ROOT={self.transient}",
                "STACK_REQUIRE_SEPARATE_FILESYSTEMS=0",
                f"STACK_PIN_TOOL={PIN_TOOL}",
                f"STACK_ARTIFACT_TOOL={ARTIFACT_TOOL}",
                f"STACK_DEADLINE_TOOL={DEADLINE_TOOL}",
                f"STACK_SWIFT_STACK_TOOL={self.stack_wrapper}",
                f"STACK_SWIFT={self.swift}",
                f"STACK_GO={self.go}",
                f"STACK_LOCK_TOOL={self.lock}",
                f"STACK_SWIFT_CONTRACT={'a' * 64}",
                f"STACK_GO_CONTRACT={'b' * 64}",
                "STACK_BUILD_STAGE_TIMEOUT_SECONDS=30",
                f"PYTHON={sys.executable}",
                f"CONTAINERIZATION_STACK_REPO={self.containerization}",
                f"CONTAINER_ENGINE_API_STACK_REPO={self.engine}",
                f"CONTAINER_STACK_REPO={self.container}",
                f"CONTAINER_BUILDER_SHIM_STACK_REPO={self.builder}",
            ],
            cwd=self.compose,
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
        self.retained.mkdir()
        (self.retained / "unrelated.txt").write_text("preserve\n", encoding="utf-8")
        result = subprocess.run(
            [
                "/usr/bin/make",
                "-f",
                str(MAKEFILE),
                "stack-state-init",
                f"STACK_RETAINED_ROOT={self.retained}",
                f"STACK_TRANSIENT_ROOT={self.transient}",
                "STACK_REQUIRE_SEPARATE_FILESYSTEMS=0",
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
            (self.retained / "unrelated.txt").read_text(encoding="utf-8"),
            "preserve\n",
        )
        self.assertFalse((self.retained / ".container-family-retained-root").exists())

    def test_retry_reuses_successful_upstream_pins_after_failure(self) -> None:
        self.fail.write_text("fail once\n", encoding="utf-8")
        failed = self.run_build()
        self.assertEqual(failed.returncode, 2, failed.stderr)
        self.assertTrue((self.retained / "pins/debug/containerization.json").is_file())
        self.assertTrue((self.retained / "pins/debug/container-engine-api.json").is_file())
        self.assertFalse((self.retained / "pins/debug/container.json").exists())

        resumed = self.run_build()
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertEqual(
            self.logged_builds(),
            ["build:cctl", "build:container-engine", "build:container", "build:container"],
        )
        self.assertTrue((self.retained / "pins/debug/container.json").is_file())

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

    def test_complete_graph_recovers_and_publishes_verified_bundle(self) -> None:
        self.fail.write_text("fail once\n", encoding="utf-8")

        failed = self.run_full_build()

        self.assertNotEqual(failed.returncode, 0)
        pin_root = self.retained / "pins/debug"
        self.assertTrue((pin_root / "containerization.json").is_file())
        self.assertTrue((pin_root / "container-engine-api.json").is_file())
        self.assertTrue((pin_root / "container-builder-shim.json").is_file())
        self.assertFalse((pin_root / "container.json").exists())
        self.assertFalse((pin_root / "container-compose.json").exists())

        resumed = self.run_full_build()

        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertEqual(
            Counter(self.logged_builds()),
            Counter(
                {
                    "build:cctl": 1,
                    "build:container-engine": 1,
                    "build:container-builder-shim": 1,
                    "build:container": 2,
                    "build:compose": 1,
                }
            ),
        )
        bundle = pin_root / "stack.json"
        self.assertTrue(bundle.is_file())
        verified = subprocess.run(
            [
                sys.executable,
                str(PIN_TOOL),
                "verify-bundle",
                "--quiet",
                "--bundle",
                str(bundle),
                "--repository",
                "containerization",
                "--repository",
                "container-engine-api",
                "--repository",
                "container",
                "--repository",
                "container-builder-shim",
                "--repository",
                "container-compose",
            ],
            check=False,
        )
        self.assertEqual(verified.returncode, 0)
        compose_pin = (pin_root / "container-compose.json").read_text(encoding="utf-8")
        self.assertIn(str(self.retained / "artifacts/objects/sha256"), compose_pin)
        self.assertNotIn(str(self.transient / "scratch"), compose_pin)
        self.assertNotIn(str(self.compose / ".build/debug/compose"), compose_pin)
        timing_logs = sorted((self.retained / "timings").glob("*.jsonl"))
        self.assertEqual(len(timing_logs), 2)
        records = [
            json.loads(line)
            for path in timing_logs
            for line in path.read_text(encoding="utf-8").splitlines()
        ]
        labels = {record["label"] for record in records}
        self.assertIn("stack-total", labels)
        self.assertIn("container-build", labels)
        self.assertIn("compose-build", labels)
        self.assertTrue(all(record["duration_seconds"] >= 0 for record in records))

        for transient_product in self.transient.glob("scratch/**/*"):
            if transient_product.is_file():
                transient_product.unlink()
        verified_after_scratch_cleanup = subprocess.run(
            [
                sys.executable,
                str(PIN_TOOL),
                "verify-bundle",
                "--quiet",
                "--bundle",
                str(bundle),
            ],
            check=False,
        )
        self.assertEqual(verified_after_scratch_cleanup.returncode, 0)

    def test_compose_build_uses_identity_preserving_manifest_overrides(self) -> None:
        makefile = MAKEFILE.read_text(encoding="utf-8")
        package = (REPOSITORY_ROOT / "Package.swift").read_text(encoding="utf-8")

        self.assertIn('CONTAINER_PACKAGE_PATH="$(CONTAINER_STACK_REPO)"', makefile)
        self.assertIn(
            'CONTAINERIZATION_PACKAGE_PATH="$(CONTAINERIZATION_STACK_REPO)"',
            makefile,
        )
        self.assertIn(
            'CONTAINER_ENGINE_API_PACKAGE_PATH="$(CONTAINER_ENGINE_API_STACK_REPO)"',
            makefile,
        )
        self.assertIn('environment["CONTAINER_PACKAGE_PATH"]', package)
        self.assertIn('"CONTAINERIZATION_PACKAGE_PATH"', package)


if __name__ == "__main__":
    unittest.main()
