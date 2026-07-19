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
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to a
#                      working "docker compose" plugin when available,
#                      otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It validates
# Docker Compose V2 host namespace behavior for service `network_mode: host`
# and `pid: host`, then checks the same Compose file through container-compose
# dry-run output. It also compares Docker Compose V2 and container-compose
# configuration for accepted PID and IPC sharing spellings, then verifies that
# container-compose refuses those runtime modes before side effects. The
# stephenlclarke runtime path maps `network_mode: host` to `container --network
# host`; Docker's service/container namespace sharing remains a later parity
# slice.

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
DOCKER_COMPOSE_COMMAND=()
DOCKER_DAEMON_AVAILABLE=0

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
}

# Create minimal Compose fixtures for host namespace and blocked sharing modes.
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
    if [[ -n "$COMPOSE_FILE" && "$DOCKER_DAEMON_AVAILABLE" == 1 ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
}

# Validate a tool's normalized config for host and blocked namespace modes.
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
pid = services["pid"]

if net.get(network_mode_field) != "host":
    raise SystemExit(f"{tool} net {network_mode_field}={net.get(network_mode_field)!r}, want 'host'")
if "networks" in net:
    raise SystemExit(f"{tool} network_mode: host service should not retain service networks")
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

# Validate Docker Compose's runtime HostConfig for host namespace modes.
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
    local run_pid_output
    local net_line
    local pid_line
    local run_net_line
    local run_pid_line
    local unsupported_output

    up_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" up net pid)"
    net_line="$(dry_run_line_for_service "$up_output" net)"
    pid_line="$(dry_run_line_for_service "$up_output" pid)"

    [[ -n "$net_line" ]] || { error 'missing dry-run command for network_mode: host service'; return 1; }
    [[ -n "$pid_line" ]] || { error 'missing dry-run command for pid: host service'; return 1; }
    [[ "$net_line" == *" --network host "* ]] || { error "network_mode: host did not emit --network host: $net_line"; return 1; }
    [[ "$net_line" != *" --network ${CONTAINER_PROJECT_NAME}_default "* ]] || { error "network_mode: host also attached the default network: $net_line"; return 1; }
    [[ "$pid_line" == *" --network ${CONTAINER_PROJECT_NAME}_default "* ]] || { error "pid: host service did not retain default network: $pid_line"; return 1; }
    [[ "$pid_line" == *" --pid host "* ]] || { error "pid: host service did not emit --pid host: $pid_line"; return 1; }

    run_net_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" run net true)"
    run_pid_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" run pid true)"
    run_net_line="$(dry_run_line_for_service "$run_net_output" net)"
    run_pid_line="$(dry_run_line_for_service "$run_pid_output" pid)"

    [[ -n "$run_net_line" ]] || { error 'missing dry-run command for one-off network_mode: host service'; return 1; }
    [[ -n "$run_pid_line" ]] || { error 'missing dry-run command for one-off pid: host service'; return 1; }
    [[ "$run_net_line" == *" --network host "* ]] || { error "one-off network_mode: host did not emit --network host: $run_net_line"; return 1; }
    [[ "$run_net_line" != *" --network ${CONTAINER_PROJECT_NAME}_default "* ]] || { error "one-off network_mode: host also attached the default network: $run_net_line"; return 1; }
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
    printf 'Docker Compose host namespace parity check passed for project %s\n' "$DOCKER_PROJECT_NAME"
}

main "$@"
