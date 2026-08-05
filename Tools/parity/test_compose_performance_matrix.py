#!/usr/bin/env python3
# Copyright 2026 container-compose project authors.
# Licensed under the Apache License, Version 2.0.

"""Focused tests for the Compose performance evidence harness."""

from __future__ import annotations

import csv
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[2]
HARNESS = REPOSITORY / "Tools" / "parity" / "check-compose-performance-matrix.sh"
FIXTURES = [
    "startup-1-services",
    "teardown-1-services",
    "startup-10-services",
    "teardown-10-services",
    "startup-50-services",
    "teardown-50-services",
    "logging-startup-first-output",
    "logging-throughput-stdout-small",
    "logging-throughput-stderr-small",
    "logging-throughput-mixed-small",
    "logging-throughput-stdout-16k",
    "logging-throughput-stdout-1m",
    "logging-read-tail-10",
    "logging-read-tail-1000",
    "logging-read-all",
    "logging-follow-rotation",
    "logging-aggregate-1-services",
    "logging-aggregate-10-services",
    "logging-aggregate-50-services",
]


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
