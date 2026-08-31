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

"""Focused tests for the Compose performance evidence harness."""

from __future__ import annotations

import csv
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[2]
HARNESS = REPOSITORY / "Tools" / "parity" / "check-compose-performance-matrix.sh"
SINK = REPOSITORY / "Tools" / "parity" / "logging_performance_sink.py"
FIXTURES = [
    "startup-1-services",
    "teardown-1-services",
    "startup-10-services",
    "teardown-10-services",
    "startup-50-services",
    "teardown-50-services",
    "logging-startup-first-output",
    "logging-startup-first-output-attached",
    "logging-throughput-stdout-small",
    "logging-throughput-stderr-small",
    "logging-throughput-mixed-small",
    "logging-throughput-stdout-16k",
    "logging-throughput-stdout-1m",
    "logging-blocking-slow-sink",
    "logging-nonblocking-64k",
    "logging-nonblocking-1m",
    "logging-nonblocking-4m",
    "logging-write-json-compression",
    "logging-write-local-rotation",
    "logging-read-tail-10",
    "logging-read-tail-1000",
    "logging-read-all",
    "logging-read-since-until",
    "logging-follow-rotation",
    "logging-dual-cache-delivery",
    "logging-dual-cache-read",
    "logging-aggregate-1-services",
    "logging-aggregate-10-services",
    "logging-aggregate-50-services",
]
INITIALIZE_EVIDENCE_SCRIPT = r'''
source "$1"

# Return a deterministic Docker engine fingerprint without a live daemon.
docker() { printf '{}\n'; }

# Return deterministic macOS hardware properties on every test host.
sysctl() {
    case "$*" in
        *hw.memsize*) printf '17179869184\n' ;;
        *) printf 'TestMac1,1\n' ;;
    esac
}

# Return a deterministic macOS version on every test host.
sw_vers() { printf '15.0\n'; }

DOCKER_COMPOSE_COMMAND=(/usr/bin/true)
CONTAINER_COMPOSE=/usr/bin/true
CONTAINER_BINARY=/usr/bin/true
PARITY_EVIDENCE_MODE=reset
initialize_evidence
printf 'existing\tdocker\t1\t1\tlower-is-better\t1.0\tsuccess\ttrue\n' >>"$TIMING_TSV"
'''


class LoggingPerformanceSinkTests(unittest.TestCase):
    def test_sink_retains_unique_markers_after_a_stall(self) -> None:
        with tempfile.TemporaryDirectory(prefix="logging-sink-test-") as directory:
            root = Path(directory)
            port_file = root / "port"
            result_file = root / "result.json"
            stop_file = root / "stop"
            process = subprocess.Popen(
                [
                    sys.executable,
                    SINK,
                    "--port-file",
                    port_file,
                    "--result-file",
                    result_file,
                    "--stop-file",
                    stop_file,
                    "--stall-seconds",
                    "0.05",
                    "--idle-timeout-seconds",
                    "0.05",
                ],
                cwd=REPOSITORY,
            )
            try:
                deadline = time.monotonic() + 5
                while not port_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                port = int(port_file.read_text(encoding="utf-8"))
                with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
                    client.sendall(
                        b"perf-record-000000\n"
                        b"perf-record-000001\n"
                        b"perf-record-000002\n"
                    )
                stop_file.touch()
                process.wait(timeout=5)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)

            result = json.loads(result_file.read_text(encoding="utf-8"))

        self.assertEqual(result["bindAddress"], "127.0.0.1")
        self.assertEqual(result["connectionCount"], 1)
        self.assertEqual(result["recordCount"], 3)
        self.assertEqual(result["firstRecord"], 0)
        self.assertEqual(result["lastRecord"], 2)
        self.assertTrue(result["recordsAreOrdered"])
        self.assertTrue(result["recordsAreUnique"])


class PerformanceMatrixInventoryTests(unittest.TestCase):
    def test_fixture_inventory_is_complete_and_stable(self) -> None:
        result = subprocess.run(
            [HARNESS, "--list-fixtures"],
            cwd=REPOSITORY,
            capture_output=True,
            check=True,
            text=True,
        )

        self.assertEqual(result.stdout.splitlines(), FIXTURES)

    def test_unattended_inventory_excludes_cross_vm_remote_sinks(self) -> None:
        environment = dict(os.environ)
        environment["PARITY_INCLUDE_REMOTE_LOGGING"] = "0"
        result = subprocess.run(
            [HARNESS, "--list-fixtures"],
            cwd=REPOSITORY,
            env=environment,
            capture_output=True,
            check=True,
            text=True,
        )

        fixtures = result.stdout.splitlines()
        self.assertIn("startup-50-services", fixtures)
        self.assertIn("logging-follow-rotation", fixtures)
        self.assertNotIn("logging-blocking-slow-sink", fixtures)
        self.assertNotIn("logging-dual-cache-delivery", fixtures)

    def test_file_logging_group_has_only_its_checkpoint_fixtures(self) -> None:
        environment = dict(os.environ)
        environment.update(
            {
                "PARITY_FIXTURE_GROUPS": "logging-file",
                "PARITY_INCLUDE_REMOTE_LOGGING": "0",
            }
        )
        result = subprocess.run(
            [HARNESS, "--list-fixtures"],
            cwd=REPOSITORY,
            env=environment,
            capture_output=True,
            check=True,
            text=True,
        )

        self.assertEqual(
            result.stdout.splitlines(),
            ["logging-write-json-compression", "logging-write-local-rotation"],
        )

    def test_unknown_fixture_group_is_rejected(self) -> None:
        environment = dict(os.environ)
        environment["PARITY_FIXTURE_GROUPS"] = "logging-file,unknown"
        result = subprocess.run(
            [HARNESS, "--list-fixtures"],
            cwd=REPOSITORY,
            env=environment,
            capture_output=True,
            check=False,
            text=True,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown PARITY_FIXTURE_GROUPS entry", result.stderr)

    def test_empty_fixture_group_is_rejected(self) -> None:
        environment = dict(os.environ)
        environment["PARITY_FIXTURE_GROUPS"] = ""
        result = subprocess.run(
            [HARNESS, "--list-fixtures"],
            cwd=REPOSITORY,
            env=environment,
            capture_output=True,
            check=False,
            text=True,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("PARITY_FIXTURE_GROUPS must not be empty", result.stderr)

    def test_append_mode_preserves_existing_samples(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-append-") as directory:
            evidence = Path(directory)
            timing = evidence / "timings.tsv"
            environment = dict(os.environ)
            environment["PARITY_EVIDENCE_DIR"] = str(evidence)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    INITIALIZE_EVIDENCE_SCRIPT
                    + "printf 'stale junit\\n' >\"$TIMING_JUNIT\"\n"
                    + "printf 'stale matrix\\n' >\"$TIMING_MATRIX\"\n"
                    + "PARITY_EVIDENCE_MODE=append\ninitialize_evidence\n",
                    "_",
                    HARNESS,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )
            retained_timing = timing.read_text(encoding="utf-8")
            junit_exists = (evidence / "timings.junit.xml").exists()
            matrix_exists = (evidence / "timing-matrix.md").exists()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("existing\tdocker", retained_timing)
        self.assertFalse(junit_exists)
        self.assertFalse(matrix_exists)

    def test_append_mode_rejects_changed_fingerprint(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-append-") as directory:
            evidence = Path(directory)
            timing = evidence / "timings.tsv"
            environment = dict(os.environ)
            environment["PARITY_EVIDENCE_DIR"] = str(evidence)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    INITIALIZE_EVIDENCE_SCRIPT
                    + "PARITY_TIMEOUT_SECONDS=123\n"
                    + "PARITY_EVIDENCE_MODE=append\n"
                    + "initialize_evidence\n",
                    "_",
                    HARNESS,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )
            retained_timing = timing.read_text(encoding="utf-8")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fingerprint does not match", result.stderr)
        self.assertIn("conditions", result.stderr)
        self.assertIn("existing\tdocker", retained_timing)

    def test_reset_mode_removes_rendered_outputs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-reset-") as directory:
            evidence = Path(directory)
            timing_junit = evidence / "timings.junit.xml"
            timing_matrix = evidence / "timing-matrix.md"
            timing_junit.write_text("stale junit\n", encoding="utf-8")
            timing_matrix.write_text("stale matrix\n", encoding="utf-8")
            environment = dict(os.environ)
            environment["PARITY_EVIDENCE_DIR"] = str(evidence)
            result = subprocess.run(
                ["bash", "-c", INITIALIZE_EVIDENCE_SCRIPT, "_", HARNESS],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )
            junit_exists = timing_junit.exists()
            matrix_exists = timing_matrix.exists()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(junit_exists)
        self.assertFalse(matrix_exists)

    def test_finalize_rejects_changed_render_controls(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-finalize-") as directory:
            evidence = Path(directory)
            environment = dict(os.environ)
            environment["PARITY_EVIDENCE_DIR"] = str(evidence)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    INITIALIZE_EVIDENCE_SCRIPT
                    + "PARITY_COMPARABLE_NOISE_PCT=7\n"
                    + "validate_finalize_fingerprint\n",
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
        self.assertIn("finalize controls do not match", result.stderr)
        self.assertIn("comparableNoisePercent", result.stderr)

    def test_finalize_rejects_changed_remote_logging_mode(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-finalize-") as directory:
            evidence = Path(directory)
            environment = dict(os.environ)
            environment["PARITY_EVIDENCE_DIR"] = str(evidence)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    INITIALIZE_EVIDENCE_SCRIPT
                    + "PARITY_INCLUDE_REMOTE_LOGGING=0\n"
                    + "validate_finalize_fingerprint\n",
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
        self.assertIn("finalize controls do not match", result.stderr)
        self.assertIn("remoteLogging", result.stderr)

    def test_finalize_rejects_fixture_inventory_before_rendering(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-finalize-") as directory:
            evidence = Path(directory)
            environment = dict(os.environ)
            environment["PARITY_EVIDENCE_DIR"] = str(evidence)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    INITIALIZE_EVIDENCE_SCRIPT + "validate_finalize_fingerprint\n",
                    "_",
                    HARNESS,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )
            junit_exists = (evidence / "timings.junit.xml").exists()
            matrix_exists = (evidence / "timing-matrix.md").exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture inventory does not match", result.stderr)
        self.assertFalse(junit_exists)
        self.assertFalse(matrix_exists)

    def test_finalize_rejects_sample_counts_before_rendering(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-finalize-") as directory:
            evidence = Path(directory)
            environment = dict(os.environ)
            environment["PARITY_EVIDENCE_DIR"] = str(evidence)
            initialized = subprocess.run(
                ["bash", "-c", INITIALIZE_EVIDENCE_SCRIPT, "_", HARNESS],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )
            self.assertEqual(initialized.returncode, 0, initialized.stderr)
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
                    writer.writerow(
                        [
                            fixture,
                            "docker",
                            1,
                            1,
                            "lower-is-better",
                            1,
                            "success",
                            "true",
                        ]
                    )
                    writer.writerow(
                        [
                            fixture,
                            "container-compose",
                            1,
                            2,
                            "lower-is-better",
                            1,
                            "success",
                            "true",
                        ]
                    )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; validate_finalize_fingerprint',
                    "_",
                    HARNESS,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )
            junit_exists = (evidence / "timings.junit.xml").exists()
            matrix_exists = (evidence / "timing-matrix.md").exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sample counts do not match", result.stderr)
        self.assertFalse(junit_exists)
        self.assertFalse(matrix_exists)

    def test_fixture_root_can_be_kept_on_internal_storage(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-work-") as directory:
            work_root = Path(directory) / "fixtures"
            environment = dict(os.environ)
            environment["PARITY_WORK_ROOT"] = str(work_root)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; create_fixtures; printf "%s\\n" "$FIXTURE_DIR"',
                    "_",
                    HARNESS,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=True,
                text=True,
            )
            fixture_root = Path(result.stdout.strip())
            self.assertEqual(fixture_root.parent, work_root)

    def test_file_logging_fixtures_retain_completed_writer_for_assertion(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-work-") as directory:
            work_root = Path(directory) / "fixtures"
            environment = dict(os.environ)
            environment["PARITY_WORK_ROOT"] = str(work_root)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; create_fixtures; printf "%s\\n" "$FIXTURE_DIR"',
                    "_",
                    HARNESS,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=True,
                text=True,
            )
            fixture_root = Path(result.stdout.strip())
            workload = (fixture_root / "logging-workload.yml").read_text(
                encoding="utf-8"
            )
            regular = (fixture_root / "logging.yml").read_text(encoding="utf-8")
            retained = [
                (fixture_root / filename).read_text(encoding="utf-8")
                for filename in (
                    "logging-json-compress.yml",
                    "logging-local.yml",
                )
            ]

        self.assertIn("LOG_RETAIN_AFTER_COMPLETION", workload)
        self.assertNotIn("LOG_COMPLETION_FILE", regular)
        for fixture in retained:
            self.assertIn("LOG_COMPLETION_FILE", fixture)
            self.assertIn("LOG_RETAIN_AFTER_COMPLETION", fixture)
            self.assertIn("target: /completion", fixture)
            self.assertIn("stop_grace_period: 1s", fixture)


class PerformanceMatrixSinkSafetyTests(unittest.TestCase):
    def test_non_loopback_sink_requires_explicit_opt_in(self) -> None:
        default_result = self.run_tool_check()
        explicit_result = self.run_tool_check(bind_address="0.0.0.0")

        self.assertNotEqual(default_result.returncode, 0)
        self.assertIn(
            "refusing to request local-network access implicitly",
            default_result.stderr,
        )
        self.assertEqual(explicit_result.returncode, 0, explicit_result.stderr)

    def test_unattended_mode_does_not_require_local_network_access(self) -> None:
        result = self.run_tool_check(include_remote_logging=False)

        self.assertEqual(result.returncode, 0, result.stderr)

    def run_tool_check(
        self,
        bind_address: str | None = None,
        include_remote_logging: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment.update(
            {
                "CONTAINER_COMPOSE": "/usr/bin/true",
                "CONTAINER_COMPOSE_CONTAINER": "/usr/bin/true",
                "PARITY_INCLUDE_REMOTE_LOGGING": (
                    "1" if include_remote_logging else "0"
                ),
            }
        )
        if bind_address is not None:
            environment["PARITY_SINK_BIND_ADDRESS"] = bind_address
        else:
            environment.pop("PARITY_SINK_BIND_ADDRESS", None)

        return subprocess.run(
            [
                "bash",
                "-c",
                (
                    'source "$1"; STRICT=1; '
                    "detect_docker_compose() { DOCKER_COMPOSE_COMMAND=(/usr/bin/true); }; "
                    "docker() { return 0; }; "
                    "check_tools"
                ),
                "_",
                HARNESS,
            ],
            cwd=REPOSITORY,
            env=environment,
            capture_output=True,
            check=False,
            text=True,
        )


class PerformanceMatrixCompletionMarkerTests(unittest.TestCase):
    def test_completion_marker_times_workload_enqueue_not_process_teardown(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-marker-test-") as directory:
            evidence = Path(directory)
            timing = evidence / "timings.tsv"
            marker = evidence / "complete"
            with timing.open("w", encoding="utf-8", newline="") as handle:
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
            environment = dict(os.environ)
            environment.update(
                {
                    "PARITY_EVIDENCE_DIR": str(evidence),
                    "PARITY_TIMEOUT_SECONDS": "2",
                }
            )

            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    (
                        'source "$1"; run_to_completion_marker marker-test '
                        'docker 1 1 "$2" python3 -c '
                        "'import pathlib,sys,time; time.sleep(0.05); "
                        "pathlib.Path(sys.argv[1]).touch()' \"$2\""
                    ),
                    "_",
                    HARNESS,
                    marker,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )
            with timing.open(encoding="utf-8", newline="") as handle:
                rows = list(csv.DictReader(handle, delimiter="\t"))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["outcome"], "success")
        self.assertGreaterEqual(float(rows[0]["duration_seconds"]), 0.04)
        self.assertIn(f"until-file:{marker}", rows[0]["command"])

    def test_file_logging_keeps_container_available_for_log_assertion(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-file-logging-test-") as directory:
            root = Path(directory)
            evidence = root / "evidence"
            fixtures = root / "fixtures"
            invocations = root / "invocations.tsv"
            fake_compose = root / "compose"
            fake_compose.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\t%s\\t%s\\n' "$LOG_WORKLOAD" "$LOG_RETAIN_AFTER_COMPLETION" "$*" >>"$INVOCATIONS"
mkdir -p "$PERF_COMPLETION_DIR"
touch "$PERF_COMPLETION_DIR/$LOG_COMPLETION_FILE"
""",
                encoding="utf-8",
            )
            fake_compose.chmod(0o755)
            environment = dict(os.environ)
            environment.update(
                {
                    "FAKE_COMPOSE": str(fake_compose),
                    "INVOCATIONS": str(invocations),
                    "PARITY_EVIDENCE_DIR": str(evidence),
                    "PARITY_PRESSURE_RECORDS": "3",
                    "PARITY_TIMEOUT_SECONDS": "2",
                    "PARITY_WORK_ROOT": str(root),
                }
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
source "$1"
mkdir -p "$PARITY_EVIDENCE_DIR" "$PARITY_WORK_ROOT/fixtures"
FIXTURE_DIR="$PARITY_WORK_ROOT/fixtures"
printf 'fixture\\tlane\\trepetition\\tschedule_position\\tdirection\\tduration_seconds\\toutcome\\tcommand\\n' >"$TIMING_TSV"
touch "$FIXTURE_DIR/logging.yml" "$FIXTURE_DIR/logging-json-compress.yml"
select_lane() { LANE_PREFIX=c; ACTIVE_COMPOSE=("$FAKE_COMPOSE"); }
down_project() { :; }
assert_logging_record_count() {
    printf 'asserted\\t%s\\t%s\\t%s\\n' \
        "$LOG_COMPLETION_FILE" "$LOG_RETAIN_AFTER_COMPLETION" \
        "$PERF_COMPLETION_DIR" >>"$INVOCATIONS"
}
run_file_logging_lane container-compose 1 2 logging-write-json-compression "$FIXTURE_DIR/logging-json-compress.yml"
""",
                    "_",
                    HARNESS,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )
            with (evidence / "timings.tsv").open(
                encoding="utf-8", newline=""
            ) as handle:
                rows = list(csv.DictReader(handle, delimiter="\t"))
            invocation_lines = invocations.read_text(encoding="utf-8").splitlines()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["outcome"], "success")
        self.assertIn("until-file:", rows[0]["command"])
        self.assertIn("pressure\t1\t", invocation_lines[0])
        self.assertIn(" up -d --pull never", invocation_lines[0])
        assertion = invocation_lines[1].split("\t")
        self.assertEqual(assertion[0], "asserted")
        self.assertEqual(
            assertion[1],
            "logging-write-json-compression-container-compose-1.done",
        )
        self.assertEqual(assertion[2], "1")
        self.assertEqual(Path(assertion[3]), fixtures / "completions")

    def test_logging_read_corpus_retains_stopped_container(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-read-corpus-test-") as directory:
            root = Path(directory)
            invocations = root / "invocations.txt"
            fake_compose = root / "compose"
            fixture = root / "logging.yml"
            fixture.touch()
            fake_compose.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$INVOCATIONS"
""",
                encoding="utf-8",
            )
            fake_compose.chmod(0o755)
            environment = dict(os.environ)
            environment.update(
                {
                    "FAKE_COMPOSE": str(fake_compose),
                    "INVOCATIONS": str(invocations),
                }
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
source "$1"
select_lane() { LANE_PREFIX=c; ACTIVE_COMPOSE=("$FAKE_COMPOSE"); }
down_project() { :; }
prepare_logging_history container-compose "$2"
""",
                    "_",
                    HARNESS,
                    fixture,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )
            invocation_lines = invocations.read_text(encoding="utf-8").splitlines()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(invocation_lines), 2)
        self.assertIn(" up -d --pull never", invocation_lines[0])
        self.assertNotIn("--abort-on-container-exit", invocation_lines[0])
        self.assertTrue(invocation_lines[1].endswith(" wait logger"))

    def test_logging_window_uses_quiet_gap_boundaries(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-read-window-test-") as directory:
            root = Path(directory)
            invocations = root / "invocations.txt"
            fixture = root / "logging.yml"
            fixture.touch()
            environment = dict(os.environ)
            environment["INVOCATIONS"] = str(invocations)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
source "$1"
select_lane() { LANE_PREFIX=c; ACTIVE_COMPOSE=(/usr/bin/true); }
down_project() { :; }
wait_for_log_text() { :; }
wait_for_log_timestamp() {
    case "$1" in
        history-before) printf '2026-08-31T12:00:00.000000Z\n' ;;
        history-window-000) printf '2026-08-31T12:00:01.000000Z\n' ;;
        history-window-099) printf '2026-08-31T12:00:02.000000Z\n' ;;
        history-after) printf '2026-08-31T12:00:03.000000Z\n' ;;
    esac
}
run_timed() { printf 'timed %s\n' "$*" >>"$INVOCATIONS"; }
assert_since_until_window() {
    printf 'asserted %s %s\n' "$2" "$3" >>"$INVOCATIONS"
}
run_logging_since_until_lane container-compose 2 1 "$2"
""",
                    "_",
                    HARNESS,
                    fixture,
                ],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                check=False,
                text=True,
            )
            invocation_lines = invocations.read_text(encoding="utf-8").splitlines()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--since 2026-08-31T12:00:00.500000Z", invocation_lines[0])
        self.assertIn("--until 2026-08-31T12:00:02.500000Z", invocation_lines[0])
        self.assertEqual(
            invocation_lines[1],
            "asserted 2026-08-31T12:00:00.500000Z 2026-08-31T12:00:02.500000Z",
        )


class PerformanceMatrixEvidenceTests(unittest.TestCase):
    def test_finalizer_reports_comparable_median_and_p95(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-test-") as directory:
            evidence = Path(directory)
            self.write_samples(evidence)

            result = self.finalize(evidence)
            matrix = (evidence / "timing-matrix.md").read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| Median ratio | P95 ratio | Comparable or better | Guard |", matrix)
        self.assertNotIn("NOT MET", matrix)
        self.assertEqual(matrix.count("| MET | PASS |"), len(FIXTURES))

    def test_finalizer_fails_an_order_of_magnitude_p95_regression(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-test-") as directory:
            evidence = Path(directory)
            self.write_samples(
                evidence,
                override={
                    ("logging-follow-rotation", "container-compose", 2): 11.0,
                },
            )

            result = self.finalize(evidence)
            matrix = (evidence / "timing-matrix.md").read_text(encoding="utf-8")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("logging-follow-rotation", result.stderr)
        self.assertIn("| logging-follow-rotation |", matrix)
        self.assertIn("| NOT MET | FAIL |", matrix)

    def test_finalizer_records_published_regression_without_gating(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-test-") as directory:
            evidence = Path(directory)
            self.write_samples(
                evidence,
                override={
                    ("logging-follow-rotation", "container-compose", 2): 11.0,
                },
            )

            result = self.finalize(evidence, timing_policy="record")
            matrix = (evidence / "timing-matrix.md").read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("recorded but not enforced", matrix)
        self.assertIn("| NOT MET | RECORDED |", matrix)

    def test_finalizer_rejects_missing_declared_fixture_samples(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-test-") as directory:
            evidence = Path(directory)
            self.write_samples(evidence, omitted_fixture="logging-read-all")

            result = self.finalize(evidence)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("logging-read-all", result.stderr)

    def test_finalizer_rejects_non_counterbalanced_schedule(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-performance-test-") as directory:
            evidence = Path(directory)
            self.write_samples(
                evidence,
                schedule_override={
                    ("logging-startup-first-output", "container-compose", 2): 2,
                },
            )

            result = self.finalize(evidence)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("logging-startup-first-output", result.stderr)

    def write_samples(
        self,
        evidence: Path,
        omitted_fixture: str | None = None,
        override: dict[tuple[str, str, int], float] | None = None,
        schedule_override: dict[tuple[str, str, int], int] | None = None,
    ) -> None:
        evidence.mkdir(parents=True, exist_ok=True)
        override = override or {}
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
                if fixture == omitted_fixture:
                    continue
                for repetition in (1, 2):
                    for lane in ("docker", "container-compose"):
                        default = 1.0 if lane == "docker" else 0.95
                        duration = override.get((fixture, lane, repetition), default)
                        position = (
                            1
                            if (repetition == 1 and lane == "docker")
                            or (repetition == 2 and lane == "container-compose")
                            else 2
                        )
                        position = schedule_override.get(
                            (fixture, lane, repetition), position
                        )
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

    def finalize(
        self, evidence: Path, timing_policy: str = "enforce"
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment.update(
            {
                "PARITY_COMPARABLE_NOISE_PCT": "5",
                "PARITY_EVIDENCE_DIR": str(evidence),
                "PARITY_REPETITIONS": "2",
                "PARITY_TIMING_POLICY": timing_policy,
                "PARITY_TIMING_MAX_RATIO": "10",
            }
        )
        return subprocess.run(
            ["bash", "-c", 'source "$1"; finalize_evidence', "_", HARNESS],
            cwd=REPOSITORY,
            env=environment,
            capture_output=True,
            check=False,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
