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

"""Focused tests for the resumable Compose isolation benchmark."""

from __future__ import annotations

import csv
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


REPOSITORY = Path(__file__).parents[2]
HARNESS = REPOSITORY / "Tools" / "parity" / "check-compose-isolation-performance.sh"
FIXTURES = [
    "startup-1-services",
    "teardown-1-services",
    "startup-10-services",
    "teardown-10-services",
    "startup-50-services",
    "teardown-50-services",
]
LANES = ("docker", "dedicated-vm", "shared-vm")


class IsolationPerformanceInventoryTests(unittest.TestCase):
    def test_fixture_inventory_is_focused_and_stable(self) -> None:
        result = subprocess.run(
            [HARNESS, "--list-fixtures"],
            cwd=REPOSITORY,
            capture_output=True,
            check=True,
            text=True,
        )

        self.assertEqual(result.stdout.splitlines(), FIXTURES)

    def test_three_lane_schedule_rotates_each_lane_through_each_position(self) -> None:
        result = self.source("for r in 1 2 3; do select_lane_order $r; printf '%s\\n' \"${LANE_ORDER[*]}\"; done")

        self.assertEqual(
            result.stdout.splitlines(),
            [
                "docker dedicated-vm shared-vm",
                "dedicated-vm shared-vm docker",
                "shared-vm docker dedicated-vm",
            ],
        )

    def test_external_ssd_is_rejected_for_timed_files(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            tools = self.storage_tools(Path(directory), "External")
            result = self.source(
                f'PATH="{tools}:$PATH"; require_internal_storage work "{directory}"'
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be on internal storage", result.stderr)

    def test_internal_storage_is_accepted_for_timed_files(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            tools = self.storage_tools(Path(directory), "Internal")
            result = self.source(
                f'PATH="{tools}:$PATH"; require_internal_storage work "{directory}"'
            )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_repetitions_require_complete_counterbalance_cycles(self) -> None:
        result = self.source(
            "ISOLATION_REPETITIONS=4; validate_repetitions"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("complete three-run", result.stderr)

    def test_remote_docker_context_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            docker = Path(directory) / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "if [ \"$1 $2\" = \"context show\" ]; then\n"
                "  printf '%s\\n' remote\n"
                "else\n"
                "  printf '%s\\n' tcp://benchmark.example:2376\n"
                "fi\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)
            result = self.source(
                f'PATH="{directory}:$PATH"; require_local_docker_context',
                environment={"DOCKER_CONTEXT": "", "DOCKER_HOST": ""},
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not local", result.stderr)

    def test_remote_docker_host_override_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            docker = Path(directory) / "docker"
            docker.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            docker.chmod(0o755)
            result = self.source(
                f'PATH="{directory}:$PATH"; require_local_docker_context',
                environment={
                    "DOCKER_CONTEXT": "",
                    "DOCKER_HOST": "ssh://benchmark.example",
                },
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DOCKER_HOST", result.stderr)

    def test_docker_context_override_takes_precedence_over_docker_host(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            docker = Path(directory) / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' tcp://benchmark.example:2376\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)
            result = self.source(
                f'PATH="{directory}:$PATH"; require_local_docker_context',
                environment={
                    "DOCKER_CONTEXT": "remote-context",
                    "DOCKER_HOST": "unix:///private/tmp/docker.sock",
                },
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("remote-context", result.stderr)
        self.assertIn("is not local", result.stderr)

    def test_docker_compose_wrapper_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            docker = Path(directory) / "docker"
            wrapper = Path(directory) / "compose-wrapper"
            docker.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            wrapper.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            docker.chmod(0o755)
            wrapper.chmod(0o755)
            result = self.source(
                f'PATH="{directory}:$PATH"; DOCKER_COMPOSE="{wrapper} compose"; '
                "detect_docker_compose"
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("same Docker CLI", result.stderr)

    def test_stopped_local_docker_skips_in_non_strict_mode(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            docker = Path(directory) / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' unix:///private/tmp/missing-docker-benchmark.sock\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)
            result = self.source(
                f'PATH="{directory}:$PATH"; DOCKER_BINARY="{docker}"; '
                "STRICT=0; require_local_docker_context",
                environment={"DOCKER_CONTEXT": "", "DOCKER_HOST": ""},
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipping Compose isolation performance matrix", result.stderr)

    def test_missing_python_skips_before_normalizer_canonicalization(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            tools = Path(directory)
            for name in ("compose", "container", "docker", "normalizer"):
                tool = tools / name
                tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                tool.chmod(0o755)
            result = self.source(
                f'PATH="{tools}"; '
                "detect_docker_compose() { DOCKER_BINARY=\"$PATH/docker\"; "
                "DOCKER_COMPOSE_COMMAND=(\"$DOCKER_BINARY\" compose); }; "
                "require_local_docker_context() { :; }; "
                "CONTAINER_COMPOSE=\"$PATH/compose\"; "
                "CONTAINER_BINARY=container; "
                "NORMALIZER_BINARY=\"$PATH/normalizer\"; "
                "STRICT=0; check_tools"
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("python3 is unavailable", result.stderr)
        self.assertNotIn("command not found", result.stderr)

    def test_namespace_is_stable_per_evidence_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            first = Path(directory) / "first"
            second = Path(directory) / "second"
            first_result = self.source(
                f'ISOLATION_EVIDENCE_DIR="{first}"; initialize_run_namespace; printf "%s" "$PROJECT_NAMESPACE"'
            )
            repeated_result = self.source(
                f'ISOLATION_EVIDENCE_DIR="{first}"; initialize_run_namespace; printf "%s" "$PROJECT_NAMESPACE"'
            )
            second_result = self.source(
                f'ISOLATION_EVIDENCE_DIR="{second}"; initialize_run_namespace; printf "%s" "$PROJECT_NAMESPACE"'
            )

        self.assertEqual(first_result.returncode, 0, first_result.stderr)
        self.assertEqual(first_result.stdout, repeated_result.stdout)
        self.assertNotEqual(first_result.stdout, second_result.stdout)

    def test_live_namespace_owner_blocks_a_second_run(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            owner = subprocess.Popen(
                [
                    "bash",
                    "-c",
                    f'source "{HARNESS}"; '
                    f'ISOLATION_EVIDENCE_DIR="{directory}"; '
                    "initialize_run_namespace; acquire_run_lock; "
                    "printf 'acquired\\n'; sleep 30",
                ],
                cwd=REPOSITORY,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                self.assertIsNotNone(owner.stdout)
                self.assertEqual(owner.stdout.readline().strip(), "acquired")
                result = self.source(
                    f'ISOLATION_EVIDENCE_DIR="{directory}"; '
                    "initialize_run_namespace; acquire_run_lock"
                )
            finally:
                owner.terminate()
                owner.communicate(timeout=5)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another isolation benchmark owns namespace", result.stderr)

    def test_retained_lock_file_is_recoverable_after_owner_exit(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            owner = self.source(
                f'ISOLATION_EVIDENCE_DIR="{directory}"; '
                "initialize_run_namespace; acquire_run_lock"
            )
            self.assertEqual(owner.returncode, 0, owner.stderr)
            result = self.source(
                f'ISOLATION_EVIDENCE_DIR="{directory}"; initialize_run_namespace; '
                "acquire_run_lock; release_run_lock"
            )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_empty_lock_file_does_not_create_stale_ownership(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            (Path(directory) / ".run-lock").touch()
            result = self.source(
                f'ISOLATION_EVIDENCE_DIR="{directory}"; initialize_run_namespace; '
                "acquire_run_lock; release_run_lock"
            )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_candidate_lane_pins_the_fingerprinted_executables(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            compose = Path(directory) / "compose"
            compose.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n%s\\n%s\\n' \"$CONTAINER_BIN\" \"$CONTAINER_COMPOSE_CONTAINER\" \"$CONTAINER_COMPOSE_NORMALIZER\"\n",
                encoding="utf-8",
            )
            compose.chmod(0o755)
            selected = Path(directory) / "selected-container"
            normalizer = Path(directory) / "selected-normalizer"
            result = self.source(
                f'CONTAINER_COMPOSE="{compose}"; CONTAINER_BINARY="{selected}"; '
                f'NORMALIZER_BINARY="{normalizer}"; '
                'select_lane shared-vm; "${ACTIVE_COMPOSE[@]}"',
                environment={
                    "CONTAINER_BIN": "/tmp/unfingerprinted-container",
                    "CONTAINER_COMPOSE_NORMALIZER": "/tmp/unfingerprinted-normalizer",
                },
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [str(selected), str(selected), str(normalizer)],
        )

    def test_candidate_lanes_do_not_project_the_runtime_bootstrap_init_image(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            compose = Path(directory) / "compose"
            compose.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"${CONTAINER_COMPOSE_INIT_IMAGE-unset}\"\n",
                encoding="utf-8",
            )
            compose.chmod(0o755)
            for lane in ("dedicated-vm", "shared-vm"):
                with self.subTest(lane=lane):
                    result = self.source(
                        f'CONTAINER_COMPOSE="{compose}"; '
                        f'select_lane {lane}; "${{ACTIVE_COMPOSE[@]}}"',
                        environment={"CONTAINER_COMPOSE_INIT_IMAGE": "vminit:runtime-bootstrap"},
                    )

                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), "")

    def test_termination_signal_exits_after_one_cleanup(self) -> None:
        result = self.source(
            "cleanup() { printf 'cleanup\\n'; }; "
            "check_tools() { :; }; "
            "initialize_run_namespace() { :; }; "
            "acquire_run_lock() { :; }; "
            "create_fixtures() { :; }; "
            'run_matrix() { kill -TERM "$$"; printf "continued\\n"; }; '
            "main"
        )

        self.assertEqual(result.returncode, 143)
        self.assertEqual(result.stdout.splitlines(), ["cleanup"])

    def test_teardown_counts_stopped_containers(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            compose = Path(directory) / "compose"
            compose.write_text(
                "#!/bin/sh\n"
                "case \" $* \" in\n"
                "  *\" ps --all -q \"*) printf '%s\\n' stopped-container ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            compose.chmod(0o755)
            result = self.source(
                f'ACTIVE_COMPOSE=("{compose}"); '
                "assert_stopped_services teardown-1-services docker 1 project fixture.yml",
                environment={"ISOLATION_EVIDENCE_DIR": directory},
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("retained 1 services", result.stderr)

    def test_every_service_is_checked_for_isolation_and_networking(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            compose = Path(directory) / "compose"
            container = Path(directory) / "container"
            compose.write_text(
                "#!/bin/sh\nprintf '%s\\n' service-one service-two\n",
                encoding="utf-8",
            )
            container.write_text(
                "#!/bin/sh\n"
                "if [ \"$2\" = service-one ]; then\n"
                "  printf '%s\\n' '[{\"configuration\":{\"effectiveIsolation\":\"shared-vm\"},\"status\":{\"networks\":[{\"network\":\"default\",\"ipv4Address\":\"192.0.2.1\"}]}}]'\n"
                "else\n"
                "  printf '%s\\n' '[{\"configuration\":{\"effectiveIsolation\":\"dedicated-vm\"},\"status\":{\"networks\":[]}}]'\n"
                "fi\n",
                encoding="utf-8",
            )
            compose.chmod(0o755)
            container.chmod(0o755)
            result = self.source(
                f'ACTIVE_COMPOSE=("{compose}"); CONTAINER_BINARY="{container}"; '
                "assert_running_services startup-2-services shared-vm 1 project fixture.yml 2",
                environment={"ISOLATION_EVIDENCE_DIR": directory},
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("service-one has no global bridge IPv4 address", result.stderr)
        self.assertIn("service-two reported effective isolation", result.stderr)
        self.assertIn("service-two has no global bridge IPv4 address", result.stderr)

    def test_fingerprint_covers_harness_fixture_and_evaluation_settings(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            root = Path(directory)
            candidate = root / "fingerprint.json"
            binary_directory = root / "bin"
            binary_directory.mkdir()
            digest = "sha256:fixture"
            docker = binary_directory / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "if [ \"$1 $2\" = \"image inspect\" ]; then\n"
                f"  printf '%s\\n' '[{{\"Id\":\"{digest}\",\"RepoDigests\":[\"alpine@{digest}\"]}}]'\n"
                "elif [ \"$1 $2\" = \"info --format\" ]; then\n"
                "  printf '%s\\n' '{\"ID\":\"docker-fixture\",\"NCPU\":8,\"MemTotal\":17179869184}'\n"
                "else\n"
                "  printf '%s\\n' 'fixture-docker-version'\n"
                "fi\n",
                encoding="utf-8",
            )
            container = binary_directory / "container"
            container.write_text(
                "#!/bin/sh\n"
                "if [ \"$1 $2\" = \"image inspect\" ]; then\n"
                f"  printf '%s\\n' '[{{\"configuration\":{{\"descriptor\":{{\"digest\":\"{digest}\"}}}},\"variants\":[{{\"digest\":\"{digest}\"}}]}}]'\n"
                "elif [ \"$1 $2 $3 $4\" = \"system status --format json\" ]; then\n"
                "  printf '%s\\n' '{\"status\":\"running\",\"apiServerCommit\":\"fixture\"}'\n"
                "elif [ \"$1 $2 $3 $4 $5\" = \"system property list --format json\" ]; then\n"
                "  printf '%s\\n' '{\"container\":{\"cpus\":8,\"memoryInBytes\":17179869184}}'\n"
                "else\n"
                "  printf '%s\\n' 'fixture-container-version'\n"
                "fi\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)
            container.chmod(0o755)
            result = self.source(
                'CONTAINER_COMPOSE=/usr/bin/true; '
                f'CONTAINER_BINARY="{container}"; '
                'NORMALIZER_BINARY=/usr/bin/true; '
                f'PATH="{binary_directory}:$PATH"; '
                'DOCKER_COMPOSE_COMMAND=(true); '
                f'DOCKER_BINARY="{docker}"; '
                'DOCKER_CONTEXT_NAME=fixture-context; '
                'DOCKER_ENDPOINT=unix:///fixture/docker.sock; '
                'PROJECT_NAMESPACE=fixture-namespace; '
                'ISOLATION_WORK_ROOT_CANONICAL=/private/tmp/fixture-work; '
                'ISOLATION_WORK_ROOT_DEVICE=/dev/disk-fixture; '
                f'write_fingerprint_candidate "{candidate}"',
                environment={
                    "COMPOSE_PARALLEL_LIMIT": "4",
                    "ISOLATION_FIXTURE_IMAGE": "isolation-fixture/alpine:3.20",
                },
            )
            payload = json.loads(candidate.read_text(encoding="utf-8"))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            payload["fixtureImage"]["reference"],
            "isolation-fixture/alpine:3.20",
        )
        self.assertEqual(payload["fixtureImage"]["commonDigests"], [digest])
        self.assertEqual(payload["dockerReference"]["context"], "fixture-context")
        self.assertEqual(
            payload["dockerReference"]["endpoint"], "unix:///fixture/docker.sock"
        )
        self.assertEqual(payload["settings"]["projectNamespace"], "fixture-namespace")
        self.assertEqual(payload["settings"]["composeParallelLimit"], "4")
        self.assertEqual(payload["normalizer"]["path"], "/usr/bin/true")
        self.assertEqual(
            payload["normalizer"]["sha256"],
            hashlib.sha256(Path("/usr/bin/true").read_bytes()).hexdigest(),
        )
        self.assertEqual(payload["dockerAuthority"]["NCPU"], 8)
        self.assertEqual(payload["containerAuthority"]["status"]["status"], "running")
        self.assertEqual(
            payload["settings"]["workRoot"],
            {"path": "/private/tmp/fixture-work", "device": "/dev/disk-fixture"},
        )
        self.assertEqual(payload["settings"]["maximumRatio"], 10)
        self.assertEqual(
            payload["harness"]["sha256"],
            hashlib.sha256(HARNESS.read_bytes()).hexdigest(),
        )

    def storage_tools(self, root: Path, location: str) -> Path:
        tools = root / "bin"
        tools.mkdir()
        df = tools / "df"
        df.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' 'Filesystem 512-blocks Used Available Capacity Mounted on'\n"
            "printf '%s\\n' '/dev/disk-test 1 1 1 1% /'\n",
            encoding="utf-8",
        )
        diskutil = tools / "diskutil"
        diskutil.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' '   Device Location: {location}'\n",
            encoding="utf-8",
        )
        df.chmod(0o755)
        diskutil.chmod(0o755)
        return tools

    def source(
        self,
        command: str,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        source_environment = dict(os.environ)
        source_environment.update(environment or {})
        return subprocess.run(
            ["bash", "-c", f'source "$1"; {command}', "_", HARNESS],
            cwd=REPOSITORY,
            env=source_environment,
            capture_output=True,
            check=False,
            text=True,
        )


class IsolationPerformanceEvidenceTests(unittest.TestCase):
    def test_finalizer_accepts_complete_counterbalanced_samples(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            evidence = Path(directory)
            self.write_samples(evidence)

            result = self.finalize(evidence)
            matrix = (evidence / "timing-matrix.md").read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(matrix.count("| MET |"), len(FIXTURES) * 2)
        self.assertEqual(matrix.count("| PASS |"), len(FIXTURES))

    def test_finalizer_rejects_a_non_counterbalanced_sample(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            evidence = Path(directory)
            self.write_samples(
                evidence,
                schedule_override={("startup-10-services", "shared-vm", 2): 1},
            )

            result = self.finalize(evidence)
            suite = ET.parse(evidence / "timings.junit.xml").getroot()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("startup-10-services", result.stderr)
        self.assertEqual(suite.attrib["failures"], "2")
        self.assertEqual(len(suite.findall(".//failure")), 2)

    def test_checkpoint_requires_both_lifecycle_timings(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-isolation-test-") as directory:
            evidence = Path(directory)
            self.write_samples(evidence, omitted=("teardown-1-services", "shared-vm", 1))
            environment = self.environment(evidence)

            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; sample_is_complete shared-vm 1 1',
                    "_",
                    HARNESS,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )

        self.assertNotEqual(result.returncode, 0)

    def write_samples(
        self,
        evidence: Path,
        omitted: tuple[str, str, int] | None = None,
        schedule_override: dict[tuple[str, str, int], int] | None = None,
    ) -> None:
        evidence.mkdir(parents=True, exist_ok=True)
        schedule_override = schedule_override or {}
        with (evidence / "timings.tsv").open(
            "w", encoding="utf-8", newline=""
        ) as handle:
            writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
            writer.writerow(
                [
                    "fixture",
                    "lane",
                    "repetition",
                    "schedule_position",
                    "direction",
                    "duration_seconds",
                    "outcome",
                    "command",
                ]
            )
            for fixture in FIXTURES:
                for repetition in (1, 2, 3):
                    order = LANES[(repetition - 1) % 3 :] + LANES[: (repetition - 1) % 3]
                    for lane in LANES:
                        if omitted == (fixture, lane, repetition):
                            continue
                        position = schedule_override.get(
                            (fixture, lane, repetition), order.index(lane) + 1
                        )
                        duration = 1.0 if lane == "docker" else 0.95
                        writer.writerow(
                            [
                                fixture,
                                lane,
                                repetition,
                                position,
                                "lower-is-better",
                                f"{duration:.9f}",
                                "success",
                                "fixture-command",
                            ]
                        )
        with (evidence / "assertions.tsv").open(
            "w", encoding="utf-8", newline=""
        ) as handle:
            writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
            writer.writerow(
                ["fixture", "lane", "repetition", "assertion", "observed", "outcome"]
            )
            for fixture in FIXTURES:
                for repetition in (1, 2, 3):
                    for lane in LANES:
                        assertions = (
                            ("running-service-count", "bridge-ipv4")
                            if fixture.startswith("startup-")
                            else ("remaining-service-count",)
                        )
                        if fixture.startswith("startup-") and lane != "docker":
                            assertions += ("effective-isolation",)
                        for assertion in assertions:
                            writer.writerow(
                                [fixture, lane, repetition, assertion, "valid", "pass"]
                            )

    def environment(self, evidence: Path) -> dict[str, str]:
        environment = dict(os.environ)
        environment.update(
            {
                "ISOLATION_COMPARABLE_NOISE_PCT": "5",
                "ISOLATION_EVIDENCE_DIR": str(evidence),
                "ISOLATION_REPETITIONS": "3",
                "ISOLATION_TIMING_MAX_RATIO": "10",
            }
        )
        return environment

    def finalize(self, evidence: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-c", 'source "$1"; finalize_evidence', "_", HARNESS],
            cwd=REPOSITORY,
            env=self.environment(evidence),
            capture_output=True,
            check=False,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
