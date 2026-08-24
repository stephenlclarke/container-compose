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

    def run_tool_check(
        self, bind_address: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment.update(
            {
                "CONTAINER_COMPOSE": "/usr/bin/true",
                "CONTAINER_COMPOSE_CONTAINER": "/usr/bin/true",
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

    def finalize(self, evidence: Path) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment.update(
            {
                "PARITY_COMPARABLE_NOISE_PCT": "5",
                "PARITY_EVIDENCE_DIR": str(evidence),
                "PARITY_REPETITIONS": "2",
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
