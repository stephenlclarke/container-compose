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

"""No-live checks for portable released Compose benchmark evidence."""

import hashlib
import unittest

import benchmark_evidence as evidence


IMAGE = "docker.io/library/alpine@sha256:" + "a" * 64
ENVIRONMENT = {"architecture": "arm64", "host_model": "Mac16,1", "host_cpus": 12,
               "host_memory_bytes": 32 * 1024**3, "macos_version": "26.0",
               "macos_build": "25A123", "docker_cli_sha256": "a" * 64,
               "colima": {"arch": "aarch64", "runtime": "docker", "cpus": 4,
                          "memory_bytes": 8 * 1024**3, "disk_bytes": 100 * 1024**3,
                          "config_sha256": "b" * 64, "binary_sha256": "c" * 64}}
BINARY = {"formula": "docker-compose", "version": "5.5.1",
          "sha256": "c" * 64, "bottleSHA256": "d" * 64,
          "bottleURL": "https://ghcr.io/v2/homebrew/core/docker-compose/blobs/sha256:" + "d" * 64}
CAPTURE = {"cleanupVerified": True, "hostRestored": True, "capturedAt": "2026-09-28T00:00:00Z",
           "hostBeforeSHA256": "1" * 64, "hostAfterSHA256": "2" * 64,
           "hostBefore": {"observedUnixSeconds": 1_000_000.0,
                          "loadAverage": [0.1, 0.2, 0.3], "powerSource": "AC",
                          "topCPUPercent": [1.2]},
           "hostAfter": {"observedUnixSeconds": 1_000_100.0,
                         "loadAverage": [0.2, 0.3, 0.4], "powerSource": "AC",
                         "topCPUPercent": [1.0]},
           "cleanupReceiptSHA256": "3" * 64,
           "dockerEngine": {"version": "29.2.1", "apiVersion": "1.53", "os": "linux",
                            "arch": "arm64", "kernelVersion": "6.12.0"}}


def samples(trial: int | None = None) -> list[dict]:
    trials = (0,) if trial == 0 else range(1, 8)
    return [{"fixture": f"{count}-services-{operation}", "lane": "docker", "trial": number,
             "seconds": count + number / 10, "status": 0, "log_sha256": "e" * 64}
            for count in (1, 3) for operation in ("up", "down") for number in trials]


class BenchmarkEvidenceTests(unittest.TestCase):
    def test_exact_reference_round_trip(self) -> None:
        workload = evidence.workload(IMAGE)
        document = evidence.reference_document(
            workload, ENVIRONMENT, BINARY, samples(), samples(0), CAPTURE)
        self.assertEqual(evidence.validate_reference(document, workload, ENVIRONMENT), document["samples"])
        self.assertEqual(workload["fixtureSHA256"]["3"], hashlib.sha256(
            evidence.fixture_text(3, IMAGE).encode()).hexdigest())

    def test_reference_rejects_missing_failed_duplicate_and_nonfinite_samples(self) -> None:
        workload = evidence.workload(IMAGE)
        for changed in (samples()[:-1], samples() + samples()[:1],
                        [{**row, "status": 1} if row["trial"] == 1 else row for row in samples()],
                        [{**row, "seconds": float("nan")} if row["trial"] == 1 else row for row in samples()],
                        [{**row, "trial": True} if row["trial"] == 1 else row for row in samples()]):
            with self.subTest(count=len(changed)):
                with self.assertRaises(ValueError):
                    evidence.reference_document(workload, ENVIRONMENT, BINARY,
                                                changed, samples(0), CAPTURE)

    def test_reference_rejects_workload_environment_or_restoration_drift(self) -> None:
        workload = evidence.workload(IMAGE)
        document = evidence.reference_document(workload, ENVIRONMENT, BINARY,
                                               samples(), samples(0), CAPTURE)
        with self.assertRaises(ValueError):
            evidence.validate_reference(document, evidence.workload(
                "docker.io/library/alpine@sha256:" + "f" * 64), ENVIRONMENT)
        with self.assertRaises(ValueError):
            evidence.validate_reference(document, workload, {**ENVIRONMENT, "architecture": "x86_64"})
        with self.assertRaises(ValueError):
            evidence.reference_document(workload, ENVIRONMENT, BINARY,
                                        samples(), samples(0), {**CAPTURE, "hostRestored": False})
        with self.assertRaises(ValueError):
            evidence.reference_document(workload, {**ENVIRONMENT, "apiKey": "secret"}, BINARY,
                                        samples(), samples(0), CAPTURE)
        with self.assertRaises(ValueError):
            evidence.reference_document(workload, ENVIRONMENT, {**BINARY, "localPath": "/private/tmp"},
                                        samples(), samples(0), CAPTURE)

    def test_host_projection_omits_process_identity_and_rejects_bad_power(self) -> None:
        raw = {"observed_unix_seconds": 1_000_000.0, "load_average": [0.1, 0.2, 0.3],
               "power": "Now drawing from 'AC Power'", "top_cpu_processes": [
                   {"pid": 123, "command": "/private/user/process", "cpu_percent": 4.2}]}
        self.assertEqual(evidence.host_projection(raw), {
            "observedUnixSeconds": 1_000_000.0, "loadAverage": [0.1, 0.2, 0.3],
            "powerSource": "AC", "topCPUPercent": [4.2]})
        with self.assertRaises(ValueError):
            evidence.host_projection({**raw, "power": "unavailable"})


if __name__ == "__main__":
    unittest.main()
