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

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
import uuid


SCRIPT = Path(__file__).with_name("manage-release-gate-runtime.sh")


class ManageReleaseGateRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="c.", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.app_root = self.root / "app"
        self.app_root.mkdir()
        (self.app_root / ".container-compose-runtime-root").write_text(
            "container-compose isolated runtime state v1\n", encoding="utf-8"
        )
        self.namespace = "io.github.stephenlclarke.container-compose.runtime.fixture"

        candidate_parent = self.root.parent / f"container-compose-runtime-{os.getuid()}"
        candidate_parent_created = not candidate_parent.exists()
        candidate_parent.mkdir(mode=0o700, exist_ok=True)
        if candidate_parent_created:
            self.addCleanup(candidate_parent.rmdir)
        self.candidate_root = candidate_parent / (
            "candidate-" + uuid.uuid4().hex[:16]
        )
        self.addCleanup(
            lambda: subprocess.run(
                ["/bin/rm", "-rf", str(self.candidate_root)], check=False
            )
        )
        (self.candidate_root / "bin").mkdir(parents=True)
        (self.candidate_root / "libexec").mkdir()
        (self.candidate_root / ".container-compose-runtime-candidate-staging").write_text(
            "container-compose runtime candidate staging v1 " + "a" * 64 + "\n",
            encoding="utf-8",
        )
        self.command_log = self.root / "commands.log"
        self.service_state = self.root / "services"
        self.process_state = self.root / "processes"
        self.ready_state = self.root / "ready"
        self.service_state.touch()
        self.process_state.touch()

        self.container_cli = self.candidate_root / "bin" / "container"
        self._write_executable(
            self.container_cli,
            """
            printf 'container:%s\n' "$*" >>"${LIFECYCLE_COMMAND_LOG:?}"
            if [[ "$*" == "system stop" ]]; then
              if [[ "${LEAVE_RUNTIME_STATE:-0}" != 1 ]]; then
                : >"${LIFECYCLE_SERVICE_STATE:?}"
                : >"${LIFECYCLE_PROCESS_STATE:?}"
              fi
              exit 0
            fi
            if [[ "${1:-}" == list ]]; then
              [[ -f "${LIFECYCLE_READY_STATE:?}" ]]
              exit
            fi
            exit 64
            """,
        )
        self.launchctl = self.root / "launchctl"
        self._write_executable(
            self.launchctl,
            """
            if [[ "${1:-}" == managername ]]; then
              printf 'Aqua\n'
              exit 0
            fi
            if [[ "${1:-}" == list ]]; then
              while read -r first second; do
                [[ -n "$first" ]] || continue
                if [[ -n "$second" ]]; then
                  printf '%s\t0\t%s\n' "$first" "$second"
                else
                  printf '991\t0\t%s\n' "$first"
                fi
              done <"${LIFECYCLE_SERVICE_STATE:?}"
              exit 0
            fi
            if [[ "${1:-}" == bootout ]]; then
              printf 'launchctl:bootout:%s\n' "${2:-}" >>"${LIFECYCLE_COMMAND_LOG:?}"
              : >"${LIFECYCLE_SERVICE_STATE:?}"
              : >"${LIFECYCLE_PROCESS_STATE:?}"
              exit 0
            fi
            exit 64
            """,
        )
        self.ps = self.root / "ps"
        self._write_executable(
            self.ps,
            """
            if [[ "$*" == '-axo pid=,uid=,command=' ]]; then
              if [[ "${FAIL_PROCESS_SNAPSHOT:-0}" == 1 ]]; then exit 70; fi
              while IFS= read -r executable; do
                [[ -n "$executable" ]] && printf '991 %s %s --fixture\n' "$(id -u)" "$executable"
              done <"${LIFECYCLE_PROCESS_STATE:?}"
              exit 0
            fi
            exit 64
            """,
        )
        self.deadline = self.root / "deadline"
        self._write_executable(
            self.deadline,
            """
            while (($#)); do
              if [[ "$1" == -- ]]; then shift; break; fi
              shift
            done
            exec "$@"
            """,
        )
        self.wrapper = self.root / "runtime-wrapper"
        self._write_executable(
            self.wrapper,
            """
            printf 'wrapper:%s\n' "$*" >>"${LIFECYCLE_COMMAND_LOG:?}"
            touch "${LIFECYCLE_READY_STATE:?}"
            """,
        )
        self.sleep = self.root / "sleep"
        self._write_executable(self.sleep, ":")

        self.environment = os.environ.copy()
        self.environment.update(
            {
                "BASH_ENV": "/dev/null",
                "ENV": "/dev/null",
                "CONTAINER_RELEASE_RUNTIME_TESTING": "1",
                "CONTAINER_RELEASE_RUNTIME_LAUNCHCTL": str(self.launchctl),
                "CONTAINER_RELEASE_RUNTIME_PS": str(self.ps),
                "CONTAINER_RELEASE_RUNTIME_SLEEP": str(self.sleep),
                "CONTAINER_RELEASE_RUNTIME_DEADLINE_RUNNER": str(self.deadline),
                "CONTAINER_RELEASE_RUNTIME_WRAPPER": str(self.wrapper),
                "CONTAINER_RELEASE_RUNTIME_WAIT_ATTEMPTS": "1",
                "LIFECYCLE_COMMAND_LOG": str(self.command_log),
                "LIFECYCLE_SERVICE_STATE": str(self.service_state),
                "LIFECYCLE_PROCESS_STATE": str(self.process_state),
                "LIFECYCLE_READY_STATE": str(self.ready_state),
            }
        )

    def _write_executable(self, path: Path, body: str) -> None:
        path.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            + textwrap.dedent(body).lstrip(),
            encoding="utf-8",
        )
        path.chmod(0o755)

    def _run(self, action: str, **environment: str) -> subprocess.CompletedProcess[str]:
        merged_environment = self.environment.copy()
        merged_environment.update(environment)
        return subprocess.run(
            [
                str(SCRIPT),
                action,
                str(self.container_cli),
                str(self.app_root),
                self.namespace,
            ],
            check=False,
            capture_output=True,
            env=merged_environment,
            text=True,
        )

    def test_validates_quiesces_and_resumes_exact_runtime(self) -> None:
        validated = self._run("validate")
        self.assertEqual(validated.returncode, 0, validated.stderr)

        self.service_state.write_text(
            f"{self.namespace}.apiserver\n", encoding="utf-8"
        )
        self.process_state.write_text(
            f"{self.candidate_root}/libexec/container-apiserver\n",
            encoding="utf-8",
        )
        quiesced = self._run("quiesce")
        self.assertEqual(quiesced.returncode, 0, quiesced.stderr)
        self.assertIn("quiesced exact release runtime namespace", quiesced.stdout)

        resumed = self._run("resume")
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertIn("resumed exact release runtime namespace", resumed.stdout)
        commands = self.command_log.read_text(encoding="utf-8")
        self.assertIn("container:system stop", commands)
        self.assertIn(f"wrapper:{self.container_cli} /usr/bin/true", commands)
        self.assertIn("container:list --all --format json", commands)

    def test_rejects_a_successful_stop_that_left_runtime_state(self) -> None:
        self.service_state.write_text(
            f"{self.namespace}.apiserver\n", encoding="utf-8"
        )
        self.process_state.write_text(
            f"{self.candidate_root}/libexec/container-apiserver\n",
            encoding="utf-8",
        )
        result = self._run("quiesce", LEAVE_RUNTIME_STATE="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("runtime services survived quiescence", result.stderr)
        self.assertIn("runtime processes survived quiescence", result.stderr)

    def test_recovers_a_stale_namespace_backed_by_the_candidate(self) -> None:
        stale_namespace = (
            "io.github.stephenlclarke.container-compose.runtime.retained"
        )
        self.service_state.write_text(
            f"991 {stale_namespace}.apiserver\n", encoding="utf-8"
        )
        self.process_state.write_text(
            f"{self.candidate_root}/libexec/container-apiserver\n",
            encoding="utf-8",
        )

        result = self._run("quiesce", LEAVE_RUNTIME_STATE="1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("recovered stale release runtime service", result.stdout)
        commands = self.command_log.read_text(encoding="utf-8")
        self.assertIn(
            f"launchctl:bootout:gui/{os.getuid()}/{stale_namespace}.apiserver",
            commands,
        )

    def test_does_not_boot_out_a_stale_namespace_without_candidate_ownership(
        self,
    ) -> None:
        stale_namespace = (
            "io.github.stephenlclarke.container-compose.runtime.unrelated"
        )
        self.service_state.write_text(
            f"991 {stale_namespace}.apiserver\n", encoding="utf-8"
        )
        self.process_state.write_text("/usr/bin/true\n", encoding="utf-8")

        result = self._run("quiesce", LEAVE_RUNTIME_STATE="1")

        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.command_log.read_text(encoding="utf-8")
        self.assertNotIn("launchctl:bootout", commands)

    def test_rejects_a_failed_process_snapshot(self) -> None:
        result = self._run("quiesce", FAIL_PROCESS_SNAPSHOT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed to inspect release runtime processes", result.stderr)

    def test_rejects_an_unmarked_application_root(self) -> None:
        (self.app_root / ".container-compose-runtime-root").unlink()
        result = self._run("validate")
        self.assertEqual(result.returncode, 2)
        self.assertIn("no valid ownership marker", result.stderr)

    def test_rejects_a_malformed_candidate_marker(self) -> None:
        marker = self.candidate_root / ".container-compose-runtime-candidate-staging"
        marker.write_text(
            "container-compose runtime candidate staging v1 not-a-digest\n",
            encoding="utf-8",
        )
        result = self._run("validate")
        self.assertEqual(result.returncode, 2)
        self.assertIn("no valid candidate marker", result.stderr)


if __name__ == "__main__":
    unittest.main()
