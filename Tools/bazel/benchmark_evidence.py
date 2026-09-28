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

"""Portable, exact-workload timing evidence for one released Compose reference."""

from __future__ import annotations

import hashlib
import json
import math
import re
from datetime import datetime, timezone


COUNTS = (1, 3)
TRIALS = 7
OPERATIONS = {
    "config": ["config", "--services"],
    "up": ["up", "--detach", "--wait", "--wait-timeout", "120", "--pull", "never"],
    "ps": ["ps"],
    "down": ["down", "--remove-orphans", "--timeout", "10"],
    "absent": ["ps", "--all", "--quiet"],
}
TIMEOUTS = {"config": 60, "up": 180, "ps": 60, "down": 120, "absent": 60}
SHA = re.compile(r"[0-9a-f]{64}\Z")
ENVIRONMENT_KEYS = frozenset({"architecture", "host_model", "host_cpus", "host_memory_bytes",
                              "macos_version", "macos_build", "colima", "docker_cli_sha256"})
COLIMA_KEYS = frozenset({"arch", "runtime", "cpus", "memory_bytes", "disk_bytes",
                         "config_sha256", "binary_sha256"})
BINARY_KEYS = frozenset({"formula", "version", "sha256", "bottleSHA256", "bottleURL"})
CAPTURE_KEYS = frozenset({"cleanupVerified", "hostRestored", "capturedAt",
                          "hostBeforeSHA256", "hostAfterSHA256", "cleanupReceiptSHA256",
                          "hostBefore", "hostAfter", "dockerEngine"})
ENGINE_KEYS = frozenset({"version", "apiVersion", "os", "arch", "kernelVersion"})
HOST_KEYS = frozenset({"observedUnixSeconds", "loadAverage", "powerSource",
                      "topCPUPercent"})


def digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def host_projection(snapshot: dict) -> dict:
    """Retain inspectable load/power measurements without PID or command paths."""
    if not isinstance(snapshot, dict):
        raise ValueError("Benchmark host snapshot is not an object")
    power = snapshot.get("power", "")
    source = ("AC" if isinstance(power, str) and "AC Power" in power else
              "Battery" if isinstance(power, str) and "Battery Power" in power else None)
    top = snapshot.get("top_cpu_processes")
    result = {"observedUnixSeconds": snapshot.get("observed_unix_seconds"),
              "loadAverage": list(snapshot.get("load_average", [])),
              "powerSource": source,
              "topCPUPercent": [row.get("cpu_percent") for row in top] if isinstance(top, list)
              and all(isinstance(row, dict) for row in top) else None}
    validate_host_projection(result)
    return result


def validate_host_projection(value: dict) -> None:
    valid_number = lambda item: (not isinstance(item, bool) and isinstance(item, (int, float))
                                 and math.isfinite(item) and item >= 0)
    if (not isinstance(value, dict) or set(value) != HOST_KEYS
            or not valid_number(value["observedUnixSeconds"])
            or value["observedUnixSeconds"] == 0
            or not isinstance(value["loadAverage"], list)
            or len(value["loadAverage"]) != 3
            or any(not valid_number(item) for item in value["loadAverage"])
            or value["powerSource"] not in ("AC", "Battery")
            or not isinstance(value["topCPUPercent"], list)
            or len(value["topCPUPercent"]) > 8
            or any(not valid_number(item) for item in value["topCPUPercent"])):
        raise ValueError("Benchmark host load/power projection is incomplete")


def fixture_text(count: int, image: str) -> str:
    if count not in COUNTS or not image or any(character.isspace() for character in image):
        raise ValueError("Only bounded one/three-service image fixtures are allowed")
    lines = ["services:"]
    for index in range(1, count + 1):
        lines += [f"  worker{index:02d}:", f"    image: {image}",
                  '    command: ["sh", "-c", "sleep 120"]',
                  "    mem_limit: 128m", "    cpus: 1.0", "    stop_grace_period: 1s",
                  "    network_mode: none"]
    return "\n".join(lines) + "\n"


def workload(image: str) -> dict:
    """Describe the fixture and commands without a candidate commit or package path."""
    if not re.fullmatch(r"docker\.io/library/alpine@sha256:[0-9a-f]{64}", image):
        raise ValueError("Benchmark workload requires the pinned Alpine image digest")
    fixtures = {str(count): hashlib.sha256(fixture_text(count, image).encode()).hexdigest()
                for count in COUNTS}
    return {"schema": 1, "kind": "compose-one-three-service-benchmark",
            "platform": "darwin-arm64", "image": image, "fixtureSHA256": fixtures,
            "counts": list(COUNTS), "warmupTrials": 1, "measuredTrials": TRIALS,
            "serviceMemoryMiB": 128, "serviceCPUs": 1,
            "projectPattern": "cfq{pid}-{count}-{trial}-{lane}",
            "composePrefix": ["-p", "{project}", "-f", "{fixture}"],
            "operations": OPERATIONS, "timeoutsSeconds": TIMEOUTS,
            "timing": {"unit": "monotonic_seconds", "start": "before_compose_command",
                       "stop": "after_compose_command_exit", "prepull": True,
                       "stateReset": "project_down_and_absence_between_trials"},
            "referenceCommand": ["docker", "--context", "colima", "compose"],
            "candidateCommand": ["container", "compose"]}


def checked_samples(rows: list[dict], lane: str, *, trial: int | None = None) -> list[dict]:
    """Require a complete unique successful timing vector, including warmups if selected."""
    expected_trials = (0,) if trial == 0 else range(1, TRIALS + 1)
    expected = {(f"{count}-services-{operation}", number)
                for count in COUNTS for operation in ("up", "down")
                for number in expected_trials}
    seen: set[tuple[str, int]] = set()
    selected = []
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("Benchmark timing sample is not an object")
        if row.get("lane") != lane or (row.get("trial") == 0) != (trial == 0):
            continue
        key = (row.get("fixture"), row.get("trial"))
        seconds = row.get("seconds")
        if (type(row.get("trial")) is not int or key not in expected or key in seen
                or type(row.get("status")) is not int or row["status"] != 0
                or isinstance(seconds, bool) or not isinstance(seconds, (int, float))
                or not math.isfinite(seconds) or seconds <= 0
                or not isinstance(row.get("log_sha256"), str)
                or not SHA.fullmatch(row["log_sha256"])):
            raise ValueError("Benchmark reference has failed, duplicate or invalid timing sample")
        seen.add(key)
        selected.append({"fixture": key[0], "lane": lane, "trial": key[1],
                         "seconds": seconds, "status": 0, "log_sha256": row["log_sha256"]})
    if seen != expected:
        raise ValueError("Benchmark reference lacks exact seven-sample fixture coverage")
    return sorted(selected, key=lambda row: (row["fixture"], row["trial"]))


def reference_document(workload_record: dict, environment: dict, binary: dict,
                       rows: list[dict], warmups: list[dict], capture: dict) -> dict:
    if (not isinstance(environment, dict) or set(environment) != ENVIRONMENT_KEYS
            or not isinstance(environment.get("colima"), dict)
            or set(environment["colima"]) != COLIMA_KEYS
            or environment.get("architecture") != "arm64"
            or environment["colima"].get("arch") != "aarch64"
            or environment["colima"].get("runtime") != "docker"
            or any(type(environment.get(key)) is not int or environment[key] <= 0
                   for key in ("host_cpus", "host_memory_bytes"))
            or any(type(environment["colima"].get(key)) is not int
                   or environment["colima"][key] <= 0
                   for key in ("cpus", "memory_bytes", "disk_bytes"))
            or any(not isinstance(environment.get(key), str) or not environment[key]
                   or len(environment[key]) > 100
                   for key in ("host_model", "macos_version", "macos_build"))
            or not all(isinstance(value, str) and SHA.fullmatch(value)
                       for value in (environment.get("docker_cli_sha256"),
                                     environment["colima"].get("config_sha256"),
                                     environment["colima"].get("binary_sha256")))):
        raise ValueError("Reference environment has unsupported or incomplete fields")
    if not isinstance(binary, dict) or set(binary) != BINARY_KEYS:
        raise ValueError("Reference binary provenance has unsupported fields")
    if not isinstance(capture, dict) or set(capture) != CAPTURE_KEYS:
        raise ValueError("Reference capture provenance has unsupported fields")
    engine = capture.get("dockerEngine")
    if (not isinstance(engine, dict) or set(engine) != ENGINE_KEYS
            or any(not isinstance(value, str) or not value or len(value) > 100
                   for value in engine.values())):
        raise ValueError("Reference Docker Engine provenance is incomplete")
    validate_host_projection(capture.get("hostBefore"))
    validate_host_projection(capture.get("hostAfter"))
    captured_at = capture.get("capturedAt", "")
    try:
        timestamp = datetime.fromisoformat(captured_at.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        timestamp = None
    if (binary.get("formula") != "docker-compose" or binary.get("version") != "5.5.1"
            or not all(isinstance(binary.get(key), str) and SHA.fullmatch(binary[key])
                       for key in ("sha256", "bottleSHA256"))
            or binary.get("bottleURL") != (
                "https://ghcr.io/v2/homebrew/core/docker-compose/blobs/sha256:"
                + binary["bottleSHA256"])
            or capture.get("cleanupVerified") is not True
            or capture.get("hostRestored") is not True
            or timestamp is None or timestamp.tzinfo != timezone.utc
            or not all(isinstance(capture.get(key), str) and SHA.fullmatch(capture[key])
                       for key in ("hostBeforeSHA256", "hostAfterSHA256", "cleanupReceiptSHA256"))):
        raise ValueError("Reference capture lacks released binary or verified restoration")
    return {"schema": 1, "kind": "compose-benchmark-reference",
            "workload": workload_record, "workloadSHA256": digest(workload_record),
            "environment": environment, "referenceBinary": binary,
            "samples": checked_samples(rows, "docker"),
            "warmups": checked_samples(warmups, "docker", trial=0),
            "capture": capture}


def validate_reference(document: dict, expected_workload: dict,
                       expected_environment: dict) -> list[dict]:
    if (document.get("schema") != 1 or document.get("kind") != "compose-benchmark-reference"
            or document.get("workload") != expected_workload
            or document.get("workloadSHA256") != digest(expected_workload)
            or document.get("environment") != expected_environment):
        raise ValueError("Published benchmark reference has an incompatible workload or environment")
    checked = reference_document(document["workload"], document["environment"],
                                 document.get("referenceBinary", {}),
                                 document.get("samples", []), document.get("warmups", []),
                                 document.get("capture", {}))
    if checked != document:
        raise ValueError("Published benchmark reference has unsupported or changed fields")
    return checked["samples"]
