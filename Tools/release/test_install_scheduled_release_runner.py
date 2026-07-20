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

"""Regression tests for the scheduled-release runner installer."""

import hashlib
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
INSTALLER = ROOT / "scripts" / "install-scheduled-release-runner.sh"
LATEST_VERSION = "2.336.0"
ARCHIVE_CONTENT = b"verified actions runner archive\n"
ARCHIVE_DIGEST = hashlib.sha256(ARCHIVE_CONTENT).hexdigest()


class ScheduledReleaseRunnerInstallerTests(unittest.TestCase):
    """Existing runners must refresh safely from the signed upstream asset."""

    def write_executable(self, path: Path, content: str) -> None:
        """Create one executable fixture command."""
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def write_runner(self, runner_dir: Path, version: str) -> None:
        """Create a configured runner fixture with a controllable version."""
        (runner_dir / "bin").mkdir(parents=True)
        (runner_dir / ".runner").write_text("configured\n", encoding="utf-8")
        self.write_executable(
            runner_dir / "bin" / "Runner.Listener",
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' "
            f"{shlex.quote(version)}\n",
        )
        self.write_executable(
            runner_dir / "svc.sh",
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf 'service:%s\\n' \"$1\" >> \"${RUNNER_TEST_LOG}\"\n",
        )

    def write_fake_tools(
        self,
        bin_dir: Path,
        advertised_digest: str = ARCHIVE_DIGEST,
        extracted_version: str = LATEST_VERSION,
    ) -> None:
        """Provide deterministic upstream-download and archive-extraction fixtures."""
        release_json = (
            '{"assets":[{"name":"actions-runner-osx-arm64-'
            f'{LATEST_VERSION}.tar.gz","digest":"sha256:{advertised_digest}"}}]}}'
        )
        self.write_executable(
            bin_dir / "gh",
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf 'gh:%s\\n' \"$*\" >> \"${RUNNER_TEST_LOG}\"\n"
            "if [[ \"$1\" == api ]]; then\n"
            f"  printf '%s\\n' {shlex.quote(release_json)}\n"
            "  exit 0\n"
            "fi\n"
            "if [[ \"$1 $2\" == 'release download' ]]; then\n"
            "  while (($#)); do\n"
            "    case \"$1\" in\n"
            "      --dir) destination=\"$2\"; shift 2 ;;\n"
            "      --pattern) asset=\"$2\"; shift 2 ;;\n"
            "      *) shift ;;\n"
            "    esac\n"
            "  done\n"
            "  printf 'verified actions runner archive\\n' > \"${destination}/${asset}\"\n"
            "  exit 0\n"
            "fi\n"
            "printf 'unexpected gh invocation: %s\\n' \"$*\" >&2\n"
            "exit 1\n",
        )
        self.write_executable(
            bin_dir / "tar",
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "while (($#)); do\n"
            "  case \"$1\" in\n"
            "    -C) destination=\"$2\"; shift 2 ;;\n"
            "    *) shift ;;\n"
            "  esac\n"
            "done\n"
            "mkdir -p \"${destination}/bin\"\n"
            "printf '%s\\n' '#!/usr/bin/env bash' 'set -euo pipefail' "
            f"\"printf '%s\\\\n' {extracted_version}\" > \"${{destination}}/bin/Runner.Listener\"\n"
            "chmod 755 \"${destination}/bin/Runner.Listener\"\n",
        )

    def run_install(
        self,
        runner_version: str,
        advertised_digest: str = ARCHIVE_DIGEST,
        extracted_version: str = LATEST_VERSION,
    ) -> subprocess.CompletedProcess[str]:
        """Run the installer function with a configured fixture runner."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            runner_dir = temporary_root / "runner"
            bin_dir = temporary_root / "bin"
            log_path = temporary_root / "runner.log"
            bin_dir.mkdir()
            self.write_runner(runner_dir, runner_version)
            self.write_fake_tools(bin_dir, advertised_digest, extracted_version)
            library = temporary_root / "installer-library.sh"
            source = INSTALLER.read_text(encoding="utf-8")
            self.assertTrue(source.rstrip().endswith('main "$@"'))
            library.write_text(source.rsplit('\nmain "$@"', 1)[0] + "\n", encoding="utf-8")
            environment = os.environ.copy()
            environment["PATH"] = f"{bin_dir}:{environment['PATH']}"
            environment["RUNNER_TEST_LOG"] = str(log_path)
            environment.pop("BASH_ENV", None)
            command = (
                f"source {shlex.quote(str(library))}\n"
                f"RUNNER_DIR={shlex.quote(str(runner_dir))}\n"
                "RUNNER_NAME=fixture-runner\n"
                "set +e\n"
                "install_runner\n"
                "installer_status=$?\n"
                "set -e\n"
                f"{shlex.quote(str(runner_dir / 'bin' / 'Runner.Listener'))} --version\n"
                f"cat {shlex.quote(str(log_path))}\n"
                "exit \"${installer_status}\"\n"
            )
            return subprocess.run(
                ["bash", "-c", command],
                capture_output=True,
                check=False,
                cwd=temporary_root,
                env=environment,
                text=True,
            )

    def test_existing_stale_runner_is_verified_updated_and_restarted(self) -> None:
        """A stale configured runner updates only after its archive verifies."""
        result = self.run_install("2.335.1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated scheduled release runner from 2.335.1 to 2.336.0", result.stdout)
        self.assertIn("2.336.0", result.stdout)
        self.assertLess(result.stdout.index("service:stop"), result.stdout.index("service:start"))
        self.assertIn("service:status", result.stdout)

    def test_current_runner_is_not_downloaded_or_restarted(self) -> None:
        """An already-current runner only reports its healthy service state."""
        result = self.run_install(LATEST_VERSION)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already current at 2.336.0", result.stdout)
        self.assertNotIn("gh:release download", result.stdout)
        self.assertNotIn("service:stop", result.stdout)
        self.assertIn("service:status", result.stdout)

    def test_digest_mismatch_keeps_the_existing_runner_in_service(self) -> None:
        """The service is untouched until the downloaded archive matches its digest."""
        result = self.run_install("2.335.1", advertised_digest="0" * 64)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("actions runner digest mismatch", result.stderr)
        self.assertNotIn("service:stop", result.stdout)

    def test_failed_version_check_restarts_the_previous_service(self) -> None:
        """An invalid extracted runner never leaves the release service stopped."""
        result = self.run_install("2.335.1", extracted_version="2.335.1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("actions runner update did not install 2.336.0", result.stderr)
        self.assertIn("service:stop", result.stdout)
        self.assertIn("service:start", result.stdout)

    def test_help_describes_proactive_runner_updates(self) -> None:
        """Operators can see that rerunning bootstrap also maintains the runner."""
        result = subprocess.run(
            ["bash", str(INSTALLER), "--help"],
            capture_output=True,
            check=False,
            cwd=ROOT,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updates an existing runner", result.stdout)


if __name__ == "__main__":
    unittest.main()
