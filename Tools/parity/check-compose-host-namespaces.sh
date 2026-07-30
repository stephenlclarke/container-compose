#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-host-namespaces.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE            Path to the container-compose binary. Defaults
#                                to the local SwiftPM debug build.
#   CONTAINER_COMPOSE_CONTAINER  Apple container runtime CLI used for live
#                                inspection. Defaults to container from PATH.
#   CONTAINER_COMPOSE_LIVE       Set to 1 when an isolated matching Apple
#                                runtime is running.
#   DOCKER_COMPOSE               Docker Compose command to compare with.
#   PARITY_EVIDENCE_DIR          Directory for raw timing, JUnit, fingerprints,
#                                and the human comparison matrix.
#   PARITY_REPETITIONS           Timed repetitions per implementation. Defaults
#                                to 3.
#   PARITY_TIMEOUT_SECONDS       Per-operation timeout. Defaults to 300.
#
# This script is intentionally local-only and is not part of CI. It validates
# Docker Compose V2 network namespace behavior for service `network_mode:
# host`/`bridge` and `pid: host`, then checks the same Compose file through
# container-compose dry-run output. When live validation is requested, it also
# proves `network_mode: bridge` uses the Apple runtime's built-in `default`
# network without creating a project-scoped network, and compares monotonic
# bridge lifecycle timings against Docker Compose. It retains raw TSV, JUnit,
# runtime fingerprints, and a Markdown comparison matrix. Docker's
# service/container namespace sharing remains a later parity slice.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
TMPDIR=""
COMPOSE_FILE=""
UNSUPPORTED_PID_FILE=""
UNSUPPORTED_IPC_FILE=""
UNSUPPORTED_NETWORK_FILE=""
DOCKER_PROJECT_NAME="container-compose-host-docker-$RANDOM-$$"
CONTAINER_PROJECT_NAME="container-compose-host-runtime-$RANDOM-$$"
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
PARITY_EVIDENCE_DIR="${PARITY_EVIDENCE_DIR:-$REPO_ROOT/.build/parity/host-namespaces}"
PARITY_REPETITIONS="${PARITY_REPETITIONS:-3}"
PARITY_TIMEOUT_SECONDS="${PARITY_TIMEOUT_SECONDS:-300}"
TIMING_TSV="$PARITY_EVIDENCE_DIR/timings.tsv"
TIMING_JUNIT="$PARITY_EVIDENCE_DIR/timings.junit.xml"
TIMING_MATRIX="$PARITY_EVIDENCE_DIR/timing-matrix.md"
FINGERPRINT_JSON="$PARITY_EVIDENCE_DIR/fingerprints.json"
DOCKER_COMPOSE_COMMAND=()
DOCKER_DAEMON_AVAILABLE=0
CONTAINER_PROJECT_STARTED=0
TIMING_INITIALIZED=0
TIMING_FINALIZED=0

# Print a warning message to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error message to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print usage text extracted from the top of this script.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-host-namespaces.sh/$SCRIPT_NAME/"
}

# Parse command-line flags.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict)
                STRICT=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done
}

# Exit cleanly for optional local runtime dependencies, or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker/container-compose host namespace parity check"
    exit 0
}

# Locate Docker Compose V2, accepting either plugin or standalone command form.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
    elif docker compose --help 2>&1 | grep -q 'Usage:.*docker compose' && docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
    else
        skip_or_fail 'Docker Compose V2 is not available'
    fi
}

# Check Docker Compose V2 and record whether the optional daemon is available.
check_docker() {
    detect_docker_compose
    if docker info >/dev/null 2>&1; then
        DOCKER_DAEMON_AVAILABLE=1
    else
        printf 'Docker daemon unavailable; checking configuration and container-compose dry-run parity only.\n'
    fi
}

# Check the configured container-compose binary.
check_container_compose() {
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi

    if ! "$CONTAINER_COMPOSE" version >/dev/null 2>&1; then
        skip_or_fail "container-compose binary could not run: $CONTAINER_COMPOSE"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]] \
        && [[ ! -x "$CONTAINER_BINARY" ]] \
        && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1
    then
        skip_or_fail "container runtime binary is not executable: $CONTAINER_BINARY"
    fi

    if [[ ! "$PARITY_REPETITIONS" =~ ^[1-9][0-9]*$ ]]; then
        error "PARITY_REPETITIONS must be a positive integer: $PARITY_REPETITIONS"
        return 2
    fi

    if [[ ! "$PARITY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
        error "PARITY_TIMEOUT_SECONDS must be a positive integer: $PARITY_TIMEOUT_SECONDS"
        return 2
    fi
}

# Create minimal Compose fixtures for supported namespace modes and blocked sharing modes.
create_fixture() {
    mkdir -p "$REPO_ROOT/.build/parity"
    TMPDIR="$(mktemp -d "$REPO_ROOT/.build/parity/host-namespaces.XXXXXX")"
    COMPOSE_FILE="$TMPDIR/compose.yml"
    UNSUPPORTED_PID_FILE="$TMPDIR/pid-service.yml"
    UNSUPPORTED_IPC_FILE="$TMPDIR/ipc-sharing.yml"
    UNSUPPORTED_NETWORK_FILE="$TMPDIR/network-service.yml"

    cat >"$COMPOSE_FILE" <<'YAML'
services:
  net:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    network_mode: host
  bridge:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    network_mode: bridge
  pid:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    pid: host
YAML

    cat >"$UNSUPPORTED_PID_FILE" <<'YAML'
services:
  db:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
  joiner:
    image: alpine:3.20
    command: ["true"]
    pid: service:db
YAML

    cat >"$UNSUPPORTED_IPC_FILE" <<'YAML'
services:
  db:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
  shareable:
    image: alpine:3.20
    command: ["true"]
    ipc: shareable
  service:
    image: alpine:3.20
    command: ["true"]
    ipc: service:db
  container:
    image: alpine:3.20
    command: ["true"]
    ipc: container:legacy
YAML

    cat >"$UNSUPPORTED_NETWORK_FILE" <<'YAML'
services:
  db:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
  joiner:
    image: alpine:3.20
    command: ["true"]
    network_mode: service:db
YAML
}

# Clean up the temporary Docker Compose project and local files.
cleanup() {
    if [[ -n "$COMPOSE_FILE" && "$CONTAINER_PROJECT_STARTED" == 1 ]]; then
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$COMPOSE_FILE" && "$DOCKER_DAEMON_AVAILABLE" == 1 ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
    if [[ "$TIMING_INITIALIZED" == 1 && "$TIMING_FINALIZED" == 0 ]]; then
        TIMING_FINALIZED=1
        finalize_timing_evidence || true
    fi
}

# Validate a tool's normalized config for supported and blocked namespace modes.
validate_config() {
    local tool="$1"
    local config_json="$2"
    local sharing_config_json="$3"
    local network_mode_field="$4"

    python3 - "$tool" "$config_json" "$sharing_config_json" "$network_mode_field" <<'PY'
import json
import sys

tool, config_json, sharing_config_json, network_mode_field = sys.argv[1:]
config = json.loads(config_json)
services = config["services"]
net = services["net"]
bridge = services["bridge"]
pid = services["pid"]

if net.get(network_mode_field) != "host":
    raise SystemExit(f"{tool} net {network_mode_field}={net.get(network_mode_field)!r}, want 'host'")
if "networks" in net:
    raise SystemExit(f"{tool} network_mode: host service should not retain service networks")
if bridge.get(network_mode_field) != "bridge":
    raise SystemExit(f"{tool} bridge {network_mode_field}={bridge.get(network_mode_field)!r}, want 'bridge'")
if "networks" in bridge:
    raise SystemExit(f"{tool} network_mode: bridge service should not retain service networks")
if pid.get("pid") != "host":
    raise SystemExit(f"{tool} pid mode={pid.get('pid')!r}, want 'host'")
if "default" not in (pid.get("networks") or {}):
    raise SystemExit(f"{tool} pid: host service should retain the default service network")

sharing_services = json.loads(sharing_config_json)["services"]
expected = {
    "shareable": "shareable",
    "service": "service:db",
    "container": "container:legacy",
}
for name, wanted in expected.items():
    actual = sharing_services[name].get("ipc")
    if actual != wanted:
        raise SystemExit(f"{tool} {name} ipc={actual!r}, want {wanted!r}")
PY
}

# Validate Docker Compose V2 and container-compose normalized configuration.
validate_config_parity() {
    local docker_config_json
    local docker_sharing_config_json
    local container_config_json
    local container_sharing_config_json

    docker_config_json="$("${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$COMPOSE_FILE" config --format json)"
    docker_sharing_config_json="$("${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$UNSUPPORTED_IPC_FILE" config --format json)"
    validate_config 'Docker Compose' "$docker_config_json" "$docker_sharing_config_json" 'network_mode'

    container_config_json="$("$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" config --format json)"
    container_sharing_config_json="$("$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$UNSUPPORTED_IPC_FILE" config --format json)"
    validate_config 'container-compose' "$container_config_json" "$container_sharing_config_json" 'networkMode'

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$UNSUPPORTED_PID_FILE" config --format json >/dev/null
    "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$UNSUPPORTED_PID_FILE" config --format json >/dev/null
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$UNSUPPORTED_NETWORK_FILE" config --format json >/dev/null
    "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$UNSUPPORTED_NETWORK_FILE" config --format json >/dev/null
}

# Validate Docker Compose's runtime HostConfig for supported namespace modes.
validate_docker_host_config() {
    if ((DOCKER_DAEMON_AVAILABLE == 0)); then
        return
    fi

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$COMPOSE_FILE" up -d --quiet-pull >/dev/null

    python3 - "$DOCKER_PROJECT_NAME" "$COMPOSE_FILE" "${DOCKER_COMPOSE_COMMAND[@]}" <<'PY'
import json
import subprocess
import sys

project, compose_file = sys.argv[1], sys.argv[2]
compose_command = sys.argv[3:]
expected = {
    "net": ("host", ""),
    "bridge": ("bridge", ""),
    "pid": (f"{project}_default", "host"),
}

for service, wanted in expected.items():
    container_id = subprocess.check_output(
        compose_command + ["-p", project, "-f", compose_file, "ps", "-q", service],
        text=True,
    ).strip()
    if not container_id:
        raise SystemExit(f"service {service!r} did not create a container")

    inspect = subprocess.check_output(["docker", "inspect", container_id], text=True)
    host_config = json.loads(inspect)[0]["HostConfig"]
    actual = (host_config.get("NetworkMode") or "", host_config.get("PidMode") or "")
    if actual != wanted:
        raise SystemExit(f"service {service!r} host config {actual!r}, want {wanted!r}")
PY
}

# Assert the Docker bridge fixture uses Docker's built-in bridge network.
assert_docker_bridge_runtime() {
    local container_id

    container_id="$("${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$COMPOSE_FILE" ps -q bridge)"
    [[ -n "$container_id" ]] || {
        error 'Docker Compose did not create the network_mode: bridge container'
        return 1
    }

    python3 - "$container_id" <<'PY'
import json
import subprocess
import sys

container_id = sys.argv[1]
container = json.loads(subprocess.check_output(["docker", "inspect", container_id], text=True))[0]
network_mode = container["HostConfig"].get("NetworkMode")
if network_mode != "bridge":
    raise SystemExit(f"Docker bridge HostConfig.NetworkMode={network_mode!r}, want 'bridge'")
PY

    if docker network inspect "${DOCKER_PROJECT_NAME}_default" >/dev/null 2>&1; then
        error "Docker network_mode: bridge created an unexpected project network: ${DOCKER_PROJECT_NAME}_default"
        return 1
    fi
}

# Assert the live Apple fixture uses only the built-in default network.
assert_container_bridge_runtime() {
    local container_id
    local inspect_json

    container_id="$("$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" ps -q bridge)"
    [[ -n "$container_id" ]] || {
        error 'container-compose did not create the network_mode: bridge container'
        return 1
    }
    inspect_json="$("$CONTAINER_BINARY" inspect "$container_id")"

    python3 - "$container_id" "$inspect_json" <<'PY'
import json
import sys

container_id, inspect_json = sys.argv[1:]
containers = json.loads(inspect_json)
if len(containers) != 1:
    raise SystemExit(f"container inspect returned {len(containers)} records for {container_id!r}, want 1")

container = containers[0]
configured = [attachment["network"] for attachment in container["configuration"].get("networks", [])]
attached = [attachment["network"] for attachment in container["status"].get("networks", [])]
if configured != ["default"]:
    raise SystemExit(f"Apple bridge configured networks={configured!r}, want ['default']")
if attached != ["default"]:
    raise SystemExit(f"Apple bridge attached networks={attached!r}, want ['default']")
PY

    if "$CONTAINER_BINARY" network list --quiet | grep -Fqx "${CONTAINER_PROJECT_NAME}_default"; then
        error "network_mode: bridge created an unexpected project network: ${CONTAINER_PROJECT_NAME}_default"
        return 1
    fi
}

# Initialize raw timing evidence and exact runtime fingerprints.
initialize_timing_evidence() {
    local docker_compose_version
    local docker_engine_version
    local container_compose_version
    local container_runtime_version
    local compose_commit
    local runtime_commit=""
    local containerization_commit=""
    local runtime_source="${CONTAINER_RUNTIME_INIT_BLOCK_REPO:-${CONTAINER_STACK_REPO:-}}"
    local containerization_source="${CONTAINERIZATION_INIT_SOURCE_PATH:-${CONTAINERIZATION_STACK_REPO:-}}"
    local hardware_model
    local hardware_memory
    local macos_version

    mkdir -p "$PARITY_EVIDENCE_DIR"
    docker_compose_version="$("${DOCKER_COMPOSE_COMMAND[@]}" version --short)"
    docker_engine_version="$(docker version --format '{{json .Server}}')"
    container_compose_version="$("$CONTAINER_COMPOSE" version)"
    container_runtime_version="$("$CONTAINER_BINARY" system version --format json)"
    compose_commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    if [[ -n "$runtime_source" && -e "$runtime_source/.git" ]]; then
        runtime_commit="$(git -C "$runtime_source" rev-parse HEAD)"
    fi
    if [[ -n "$containerization_source" && -e "$containerization_source/.git" ]]; then
        containerization_commit="$(git -C "$containerization_source" rev-parse HEAD)"
    fi
    hardware_model="$(sysctl -n hw.model)"
    hardware_memory="$(sysctl -n hw.memsize)"
    macos_version="$(sw_vers -productVersion)"

    python3 - \
        "$TIMING_TSV" \
        "$FINGERPRINT_JSON" \
        "$docker_compose_version" \
        "$docker_engine_version" \
        "$container_compose_version" \
        "$container_runtime_version" \
        "$compose_commit" \
        "$runtime_commit" \
        "$containerization_commit" \
        "$hardware_model" \
        "$hardware_memory" \
        "$macos_version" \
        "$(uname -m)" \
        "$(shasum -a 256 "$CONTAINER_COMPOSE" | awk '{print $1}')" \
        "$(shasum -a 256 "$CONTAINER_BINARY" | awk '{print $1}')" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

(
    timing_path,
    fingerprint_path,
    docker_compose_version,
    docker_engine_raw,
    container_compose_version,
    container_runtime_raw,
    compose_commit,
    runtime_commit,
    containerization_commit,
    hardware_model,
    hardware_memory,
    macos_version,
    architecture,
    compose_sha256,
    runtime_sha256,
) = sys.argv[1:]


def decoded_or_raw(value):
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


pathlib.Path(timing_path).write_text(
    "fixture\tlane\trepetition\tduration_seconds\toutcome\tcommand\n",
    encoding="utf-8",
)
fingerprints = {
    "capturedAt": datetime.now(timezone.utc).isoformat(),
    "host": {
        "architecture": architecture,
        "hardwareMemoryBytes": int(hardware_memory),
        "hardwareModel": hardware_model,
        "macOSVersion": macos_version,
    },
    "docker": {
        "composeVersion": docker_compose_version,
        "engine": decoded_or_raw(docker_engine_raw),
    },
    "containerCompose": {
        "commit": compose_commit,
        "sha256": compose_sha256,
        "version": container_compose_version,
    },
    "containerRuntime": {
        "commit": runtime_commit or None,
        "sha256": runtime_sha256,
        "version": decoded_or_raw(container_runtime_raw),
    },
    "containerization": {
        "commit": containerization_commit or None,
    },
}
pathlib.Path(fingerprint_path).write_text(
    json.dumps(fingerprints, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

# Run one parity operation with a monotonic timeout and append its raw result.
run_timed() {
    local fixture="$1"
    local lane="$2"
    local repetition="$3"
    shift 3

    python3 - \
        "$TIMING_TSV" \
        "$fixture" \
        "$lane" \
        "$repetition" \
        "$PARITY_TIMEOUT_SECONDS" \
        "$@" <<'PY'
import csv
import os
import shlex
import signal
import subprocess
import sys
import time

timing_path, fixture, lane, repetition, timeout_raw, *command = sys.argv[1:]
timeout = float(timeout_raw)
started = time.monotonic()
process = subprocess.Popen(
    command,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    text=True,
    start_new_session=True,
)
outcome = "success"
try:
    _, stderr = process.communicate(timeout=timeout)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    _, stderr = process.communicate()
    outcome = "timeout"
else:
    if process.returncode != 0:
        outcome = f"exit-{process.returncode}"
duration = time.monotonic() - started

with open(timing_path, "a", encoding="utf-8", newline="") as timing_file:
    writer = csv.writer(timing_file, delimiter="\t", lineterminator="\n")
    writer.writerow(
        [
            fixture,
            lane,
            repetition,
            f"{duration:.9f}",
            outcome,
            shlex.join(command),
        ]
    )

print(f"{fixture} {lane} repetition {repetition}: {duration:.3f}s ({outcome})")
if outcome != "success":
    if stderr:
        print(stderr, file=sys.stderr, end="" if stderr.endswith("\n") else "\n")
    raise SystemExit(124 if outcome == "timeout" else process.returncode or 1)
PY
}

# Render JUnit and Markdown timing evidence, then enforce the 10x threshold.
finalize_timing_evidence() {
    python3 - "$TIMING_TSV" "$TIMING_JUNIT" "$TIMING_MATRIX" <<'PY'
import csv
import pathlib
import statistics
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

timing_path, junit_path, matrix_path = map(pathlib.Path, sys.argv[1:])
rows = list(csv.DictReader(timing_path.open(encoding="utf-8"), delimiter="\t"))
grouped = defaultdict(lambda: defaultdict(list))
for row in rows:
    grouped[row["fixture"]][row["lane"]].append(row)

failures = []
matrix_rows = []
testsuite = ET.Element(
    "testsuite",
    name="compose-host-namespace-performance",
    tests=str(len(grouped)),
)

for fixture in sorted(grouped):
    lanes = grouped[fixture]
    docker_rows = lanes.get("docker", [])
    candidate_rows = lanes.get("container-compose", [])
    testcase = ET.SubElement(testsuite, "testcase", classname="parity.performance", name=fixture)
    system_out = ET.SubElement(testcase, "system-out")
    system_out.text = "\n".join(
        f"{row['lane']} repetition={row['repetition']} duration={row['duration_seconds']} outcome={row['outcome']}"
        for row in docker_rows + candidate_rows
    )

    bad_rows = [row for row in docker_rows + candidate_rows if row["outcome"] != "success"]
    if bad_rows or not docker_rows or not candidate_rows:
        reason = "fixture did not complete successfully in both lanes"
        failure = ET.SubElement(testcase, "failure", message=reason)
        failure.text = "\n".join(str(row) for row in bad_rows)
        failures.append(f"{fixture}: {reason}")
        matrix_rows.append((fixture, "n/a", "n/a", "n/a", "FAIL"))
        continue

    docker_median = statistics.median(float(row["duration_seconds"]) for row in docker_rows)
    candidate_median = statistics.median(float(row["duration_seconds"]) for row in candidate_rows)
    ratio = candidate_median / docker_median if docker_median > 0 else float("inf")
    testcase.set("time", f"{candidate_median:.9f}")
    result = "PASS"
    if ratio >= 10.0:
        reason = f"candidate median is {ratio:.2f}x the Docker reference; threshold is <10x"
        failure = ET.SubElement(testcase, "failure", message=reason)
        failure.text = reason
        failures.append(f"{fixture}: {reason}")
        result = "FAIL"
    matrix_rows.append(
        (
            fixture,
            f"{docker_median:.3f}",
            f"{candidate_median:.3f}",
            f"{ratio:.2f}x",
            result,
        )
    )

testsuite.set("failures", str(len(failures)))
ET.ElementTree(testsuite).write(junit_path, encoding="utf-8", xml_declaration=True)

matrix_lines = [
    "# Host Namespace Timing Comparison",
    "",
    "| Fixture | Docker Compose median (s) | container-compose median (s) | Candidate/reference | Result |",
    "| --- | ---: | ---: | ---: | --- |",
]
matrix_lines.extend(f"| {' | '.join(row)} |" for row in matrix_rows)
matrix_lines.extend(
    [
        "",
        "Raw repetitions are retained in `timings.tsv`; exact host and runtime fingerprints are retained in `fingerprints.json`.",
        "",
    ]
)
matrix_path.write_text("\n".join(matrix_lines), encoding="utf-8")
print("\n".join(matrix_lines))

if failures:
    raise SystemExit("\n".join(failures))
PY
}

# Compare live bridge lifecycle timing through equivalent warm-image fixtures.
validate_live_bridge_parity_and_timing() {
    local repetition

    if [[ "$CONTAINER_COMPOSE_LIVE" != "1" ]]; then
        printf 'Live Apple runtime validation not requested; configuration and dry-run parity passed.\n'
        return
    fi
    if ((DOCKER_DAEMON_AVAILABLE == 0)); then
        skip_or_fail 'Docker daemon is unavailable for live bridge timing parity'
    fi

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$COMPOSE_FILE" pull --quiet bridge >/dev/null
    "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" pull --quiet bridge >/dev/null
    initialize_timing_evidence
    TIMING_INITIALIZED=1

    for ((repetition = 1; repetition <= PARITY_REPETITIONS; repetition++)); do
        run_timed \
            'network-mode-bridge-up' \
            'docker' \
            "$repetition" \
            "${DOCKER_COMPOSE_COMMAND[@]}" \
            -p "$DOCKER_PROJECT_NAME" \
            -f "$COMPOSE_FILE" \
            up -d --no-deps --pull never bridge
        assert_docker_bridge_runtime
        run_timed \
            'network-mode-bridge-down' \
            'docker' \
            "$repetition" \
            "${DOCKER_COMPOSE_COMMAND[@]}" \
            -p "$DOCKER_PROJECT_NAME" \
            -f "$COMPOSE_FILE" \
            down --volumes --remove-orphans

        run_timed \
            'network-mode-bridge-up' \
            'container-compose' \
            "$repetition" \
            "$CONTAINER_COMPOSE" \
            --ansi never \
            -p "$CONTAINER_PROJECT_NAME" \
            -f "$COMPOSE_FILE" \
            up -d --no-deps --pull never bridge
        CONTAINER_PROJECT_STARTED=1
        assert_container_bridge_runtime
        run_timed \
            'network-mode-bridge-down' \
            'container-compose' \
            "$repetition" \
            "$CONTAINER_COMPOSE" \
            --ansi never \
            -p "$CONTAINER_PROJECT_NAME" \
            -f "$COMPOSE_FILE" \
            down --remove-orphans
        CONTAINER_PROJECT_STARTED=0
    done

    TIMING_FINALIZED=1
    finalize_timing_evidence
}

# Return the first dry-run command line for a service container.
dry_run_line_for_service() {
    local output="$1"
    local service="$2"
    local name_pattern="$CONTAINER_PROJECT_NAME-$service-"

    printf '%s\n' "$output" | grep -F "container run --name $name_pattern" | head -n 1
}

# Validate container-compose dry-run output for supported and blocked modes.
validate_container_compose_dry_run() {
    local up_output
    local run_net_output
    local run_bridge_output
    local run_pid_output
    local net_line
    local bridge_line
    local pid_line
    local run_net_line
    local run_bridge_line
    local run_pid_line
    local unsupported_output

    up_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" up net bridge pid)"
    net_line="$(dry_run_line_for_service "$up_output" net)"
    bridge_line="$(dry_run_line_for_service "$up_output" bridge)"
    pid_line="$(dry_run_line_for_service "$up_output" pid)"

    [[ -n "$net_line" ]] || { error 'missing dry-run command for network_mode: host service'; return 1; }
    [[ -n "$bridge_line" ]] || { error 'missing dry-run command for network_mode: bridge service'; return 1; }
    [[ -n "$pid_line" ]] || { error 'missing dry-run command for pid: host service'; return 1; }
    [[ "$net_line" == *" --network host "* ]] || { error "network_mode: host did not emit --network host: $net_line"; return 1; }
    [[ "$net_line" != *" --network ${CONTAINER_PROJECT_NAME}_default "* ]] || { error "network_mode: host also attached the default network: $net_line"; return 1; }
    [[ "$bridge_line" == *" --network default "* ]] || { error "network_mode: bridge did not emit --network default: $bridge_line"; return 1; }
    [[ "$bridge_line" != *" --network ${CONTAINER_PROJECT_NAME}_default "* ]] || { error "network_mode: bridge also attached the project default network: $bridge_line"; return 1; }
    [[ "$pid_line" == *" --network ${CONTAINER_PROJECT_NAME}_default,alias=pid "* ]] || { error "pid: host service did not retain its default network service alias: $pid_line"; return 1; }
    [[ "$pid_line" == *" --pid host "* ]] || { error "pid: host service did not emit --pid host: $pid_line"; return 1; }

    run_net_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" run net true)"
    run_bridge_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" run bridge true)"
    run_pid_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" run pid true)"
    run_net_line="$(dry_run_line_for_service "$run_net_output" net)"
    run_bridge_line="$(dry_run_line_for_service "$run_bridge_output" bridge)"
    run_pid_line="$(dry_run_line_for_service "$run_pid_output" pid)"

    [[ -n "$run_net_line" ]] || { error 'missing dry-run command for one-off network_mode: host service'; return 1; }
    [[ -n "$run_bridge_line" ]] || { error 'missing dry-run command for one-off network_mode: bridge service'; return 1; }
    [[ -n "$run_pid_line" ]] || { error 'missing dry-run command for one-off pid: host service'; return 1; }
    [[ "$run_net_line" == *" --network host "* ]] || { error "one-off network_mode: host did not emit --network host: $run_net_line"; return 1; }
    [[ "$run_net_line" != *" --network ${CONTAINER_PROJECT_NAME}_default "* ]] || { error "one-off network_mode: host also attached the default network: $run_net_line"; return 1; }
    [[ "$run_bridge_line" == *" --network default "* ]] || { error "one-off network_mode: bridge did not emit --network default: $run_bridge_line"; return 1; }
    [[ "$run_bridge_line" != *" --network ${CONTAINER_PROJECT_NAME}_default "* ]] || { error "one-off network_mode: bridge also attached the project default network: $run_bridge_line"; return 1; }
    [[ "$run_pid_line" == *" --network ${CONTAINER_PROJECT_NAME}_default "* ]] || { error "one-off pid: host service did not retain default network: $run_pid_line"; return 1; }
    [[ "$run_pid_line" == *" --pid host "* ]] || { error "one-off pid: host service did not emit --pid host: $run_pid_line"; return 1; }

    unsupported_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$UNSUPPORTED_PID_FILE" up joiner 2>&1 || true)"
    [[ "$unsupported_output" == *"service 'joiner' uses pid 'service:db'; supported values are host and private"* ]] || {
        error "pid service-sharing blocker changed: $unsupported_output"
        return 1
    }

    for service in shareable service container; do
        unsupported_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$UNSUPPORTED_IPC_FILE" up "$service" 2>&1 || true)"
        case "$service" in
            shareable) expected_ipc='shareable' ;;
            service) expected_ipc='service:db' ;;
            container) expected_ipc='container:legacy' ;;
        esac
        [[ "$unsupported_output" == *"service '$service' uses ipc '$expected_ipc'; supported values are host and private"* ]] || {
            error "IPC namespace-sharing blocker changed for $service: $unsupported_output"
            return 1
        }
    done

    unsupported_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$UNSUPPORTED_NETWORK_FILE" up joiner 2>&1 || true)"
    [[ "$unsupported_output" == *"service 'joiner' uses network_mode 'service:db'; network mode support needs an apple/container runtime gap PR"* ]] || {
        error "network service-sharing blocker changed: $unsupported_output"
        return 1
    }
}

# Run the local-only Docker Compose V2 parity check.
main() {
    parse_args "$@"
    check_docker
    check_container_compose
    create_fixture
    trap cleanup EXIT

    validate_config_parity
    validate_docker_host_config
    validate_container_compose_dry_run
    validate_live_bridge_parity_and_timing
    printf 'Docker Compose supported namespace-mode parity check passed for project %s\n' "$DOCKER_PROJECT_NAME"
}

main "$@"
