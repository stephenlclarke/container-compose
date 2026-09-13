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

"""Regression tests for unattended Developer ID keychain isolation."""

from __future__ import annotations

import base64
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "Tools/release/temporary-developer-id-keychain.sh"
DEADLINE_RUNNER = ROOT / "Tools/ci/run-command-with-deadline.py"
IDENTITY = "A" * 40


class TemporaryDeveloperIDKeychainTests(unittest.TestCase):
    """The release keychain must be bounded, isolated, and recoverable."""

    def write_executable(self, path: Path, body: str) -> None:
        path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
        path.chmod(0o755)

    def fixture(self, root: Path) -> dict[str, str]:
        binary_root = root / "bin"
        binary_root.mkdir()
        trace = root / "trace"
        security = binary_root / "security"
        codesign = binary_root / "codesign"
        openssl = binary_root / "openssl"
        self.write_executable(
            security,
            f"""
            #!/bin/bash
            set -euo pipefail
            printf 'security:%s\n' "$1" >> "${{TRACE}}"
            case "$1" in
              list-keychains)
                if [[ " $* " != *" -s "* ]]; then
                  if [[ "${{FIXTURE_FAIL_LIST_KEYCHAINS:-0}}" == 1 ]]; then
                    exit 41
                  fi
                  printf '"%s"\n' "${{FIXTURE_LOGIN_KEYCHAIN}}"
                elif [[ "${{FIXTURE_FAIL_RESTORE:-0}}" == 1 ]]; then
                  exit 42
                fi
                ;;
              create-keychain)
                touch "${{@: -1}}"
                ;;
              delete-keychain)
                if [[ "${{FIXTURE_FAIL_DELETE:-0}}" == 1 ]]; then
                  exit 43
                fi
                rm -f "$2"
                ;;
              find-identity)
                printf '  1) {IDENTITY} "Developer ID Application: Fixture"\n'
                ;;
              find-certificate)
                printf '%s\n' fixture-certificate
                ;;
            esac
            """,
        )
        self.write_executable(
            codesign,
            """
            #!/bin/bash
            set -euo pipefail
            printf 'codesign:%s\n' "$1" >> "${TRACE}"
            """,
        )
        self.write_executable(
            openssl,
            """
            #!/bin/bash
            set -euo pipefail
            printf 'openssl:%s\n' "$1" >> "${TRACE}"
            if [[ "$1" == rand ]]; then
              printf '%064d\n' 0
            fi
            """,
        )
        keychain = root / "operation.keychain-db"
        original = root / "original.keychains"
        environment_file = root / "github.env"
        login_keychain = root / "login.keychain-db"
        login_keychain.touch()
        return {
            **os.environ,
            "TEMPORARY_DEVELOPER_ID_KEYCHAIN_TESTING": "1",
            "DEVELOPER_ID_APPLICATION_P12_BASE64": base64.b64encode(
                b"fixture-p12"
            ).decode("ascii"),
            "DEVELOPER_ID_APPLICATION_P12_PASSWORD": "fixture-password",
            "DEVELOPER_ID_TEMPORARY_ROOT": str(root),
            "DEVELOPER_ID_KEYCHAIN": str(keychain),
            "DEVELOPER_ID_ORIGINAL_KEYCHAINS": str(original),
            "DEVELOPER_ID_ENVIRONMENT_FILE": str(environment_file),
            "DEVELOPER_ID_EXPECTED_IDENTITY": "Developer ID Application: Fixture",
            "DEVELOPER_ID_SECURITY": str(security),
            "DEVELOPER_ID_CODESIGN": str(codesign),
            "DEVELOPER_ID_OPENSSL": str(openssl),
            "DEVELOPER_ID_PYTHON": "/usr/bin/python3",
            "DEVELOPER_ID_DEADLINE_RUNNER": str(DEADLINE_RUNNER),
            "TRACE": str(trace),
            "FIXTURE_LOGIN_KEYCHAIN": str(login_keychain),
        }

    def run_script(
        self, mode: str, environment: dict[str, str]
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), mode],
            cwd=ROOT,
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
            timeout=20,
        )

    def test_install_and_cleanup_never_use_the_login_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root)

            installed = self.run_script("install", environment)

            self.assertEqual(installed.returncode, 0, installed.stderr)
            self.assertEqual(installed.stdout, "")
            self.assertNotIn("fixture-password", installed.stderr)
            keychain = Path(environment["DEVELOPER_ID_KEYCHAIN"])
            original = Path(environment["DEVELOPER_ID_ORIGINAL_KEYCHAINS"])
            self.assertTrue(keychain.is_file())
            self.assertTrue(original.is_file())
            exported = Path(environment["DEVELOPER_ID_ENVIRONMENT_FILE"]).read_text(
                encoding="utf-8"
            )
            self.assertIn(f"DEVELOPER_ID_APPLICATION_IDENTITY={IDENTITY}", exported)
            self.assertIn(f"CONTAINER_RUNTIME_CODESIGN_IDENTITY={IDENTITY}", exported)
            self.assertNotIn("fixture-password", exported)

            cleaned = self.run_script("cleanup", environment)

            self.assertEqual(cleaned.returncode, 0, cleaned.stderr)
            self.assertFalse(keychain.exists())
            self.assertFalse(original.exists())
            trace = (root / "trace").read_text(encoding="utf-8")
            self.assertIn("security:import", trace)
            self.assertIn("security:delete-keychain", trace)
            self.assertIn("codesign:--force", trace)
            self.assertIn("codesign:--verify", trace)

    def test_identity_mismatch_removes_partial_keychain(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root)
            environment["DEVELOPER_ID_EXPECTED_IDENTITY"] = "B" * 40

            installed = self.run_script("install", environment)

            self.assertNotEqual(installed.returncode, 0)
            self.assertIn("fingerprint does not match", installed.stderr)
            self.assertFalse(Path(environment["DEVELOPER_ID_KEYCHAIN"]).exists())
            self.assertFalse(
                Path(environment["DEVELOPER_ID_ORIGINAL_KEYCHAINS"]).exists()
            )

    def test_install_requires_the_configured_release_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root)
            environment.pop("DEVELOPER_ID_EXPECTED_IDENTITY")

            installed = self.run_script("install", environment)

            self.assertNotEqual(installed.returncode, 0)
            self.assertIn("EXPECTED_IDENTITY is required", installed.stderr)
            self.assertFalse(Path(environment["DEVELOPER_ID_KEYCHAIN"]).exists())

    def test_failed_search_list_capture_never_publishes_a_restore_record(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root)
            environment["FIXTURE_FAIL_LIST_KEYCHAINS"] = "1"

            installed = self.run_script("install", environment)

            self.assertNotEqual(installed.returncode, 0)
            self.assertFalse(
                Path(environment["DEVELOPER_ID_ORIGINAL_KEYCHAINS"]).exists()
            )
            self.assertFalse(Path(environment["DEVELOPER_ID_KEYCHAIN"]).exists())

    def test_failed_cleanup_retains_recovery_state_for_a_later_retry(self) -> None:
        for failure in ("FIXTURE_FAIL_RESTORE", "FIXTURE_FAIL_DELETE"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                environment = self.fixture(root)
                installed = self.run_script("install", environment)
                self.assertEqual(installed.returncode, 0, installed.stderr)
                original = Path(environment["DEVELOPER_ID_ORIGINAL_KEYCHAINS"])

                environment[failure] = "1"
                cleaned = self.run_script("cleanup", environment)

                self.assertNotEqual(cleaned.returncode, 0)
                self.assertTrue(original.is_file())

                environment.pop(failure)
                retried = self.run_script("cleanup", environment)
                self.assertEqual(retried.returncode, 0, retried.stderr)
                self.assertFalse(original.exists())
                self.assertFalse(Path(environment["DEVELOPER_ID_KEYCHAIN"]).exists())

    def test_install_rejects_a_keychain_outside_the_temporary_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root)
            environment["DEVELOPER_ID_KEYCHAIN"] = "/tmp/not-owned.keychain-db"

            installed = self.run_script("install", environment)

            self.assertNotEqual(installed.returncode, 0)
            self.assertIn("must be a direct child", installed.stderr)
            self.assertFalse((root / "trace").exists())

    def test_install_rejects_missing_certificate_secret(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root)
            environment.pop("DEVELOPER_ID_APPLICATION_P12_BASE64")

            installed = self.run_script("install", environment)

            self.assertNotEqual(installed.returncode, 0)
            self.assertIn("P12_BASE64 is required", installed.stderr)


if __name__ == "__main__":
    unittest.main()
