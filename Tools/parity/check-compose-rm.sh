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
#   check-compose-rm.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or the Docker daemon is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   DOCKER_COMPOSE  Docker Compose command to compare with. Defaults to
#                   "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It verifies the
# Docker Compose V2 `rm` lifecycle behavior mirrored by container-compose:
# missing service containers are treated as "No stopped containers", running
# containers are not removed without --stop, and rm --stop removes them.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME

STRICT=0
TMPDIR=""
COMPOSE_FILE=""
PROJECT_NAME="container-compose-rm-$RANDOM-$$"
DOCKER_COMPOSE_COMMAND=()

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-rm.sh/$SCRIPT_NAME/"
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

# Exit cleanly for optional Docker dependencies, or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose rm parity check"
    exit 0
}

# Locate Docker Compose V2, accepting either plugin or standalone command form.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
    else
        skip_or_fail 'Docker Compose V2 is not available'
    fi
}

# Check Docker Compose V2 and daemon availability.
check_docker() {
    detect_docker_compose
    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker daemon is not available'
    fi
}

# Create a minimal service that can be created, removed externally, and run.
create_fixture() {
    TMPDIR="$(mktemp -d)"
    COMPOSE_FILE="$TMPDIR/compose.yml"

    cat >"$COMPOSE_FILE" <<'YAML'
services:
  app:
    image: busybox:latest
    command: ["sh", "-c", "sleep 60"]
YAML
}

# Remove temporary files and any project resources left by a failed probe.
cleanup() {
    local status=$?

    if [[ -n "$COMPOSE_FILE" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi

    exit "$status"
}

# Capture a Docker Compose command's output while preserving its exit status.
capture_compose() {
    local output_var="$1"
    local status_var="$2"
    shift 2

    local captured
    local rc
    set +e
    captured="$("${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@" 2>&1)"
    rc=$?
    set -e

    printf -v "$output_var" '%s' "$captured"
    printf -v "$status_var" '%s' "$rc"
}

# Assert captured output and status match Docker Compose rm expectations.
expect_no_stopped_containers() {
    local output="$1"
    local status="$2"

    if [[ "$status" != "0" ]]; then
        error "expected Docker Compose rm to exit 0, got $status"
        printf '%s\n' "$output" >&2
        return 1
    fi
    if [[ "$output" != *"No stopped containers"* ]]; then
        error "expected Docker Compose rm output to contain 'No stopped containers'"
        printf '%s\n' "$output" >&2
        return 1
    fi
}

# Verify Docker Compose reference behavior for rm.
check_docker_compose_rm() {
    local output=""
    local status=""
    local container_id=""
    local running_state=""

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" create app >/dev/null
    container_id="$("${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" ps --all -q app)"
    docker rm -f "$container_id" >/dev/null

    capture_compose output status rm -f app
    expect_no_stopped_containers "$output" "$status"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d app >/dev/null
    capture_compose output status rm -f app
    expect_no_stopped_containers "$output" "$status"

    container_id="$("${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" ps --all -q app)"
    running_state="$(docker inspect -f '{{.State.Status}}' "$container_id")"
    if [[ "$running_state" != "running" ]]; then
        error "expected rm -f without --stop to leave the container running, got $running_state"
        return 1
    fi

    capture_compose output status rm --stop --force app
    if [[ "$status" != "0" ]]; then
        error "expected Docker Compose rm --stop --force to exit 0, got $status"
        printf '%s\n' "$output" >&2
        return 1
    fi
    if docker inspect "$container_id" >/dev/null 2>&1; then
        error 'expected Docker Compose rm --stop --force to remove the running container'
        return 1
    fi
}

# Verify the local container-compose implementation through focused tests.
check_container_compose_rm_tests() {
    swift test --disable-automatic-resolution --filter 'rmSkipsRunningContainersUnlessStopIsRequested|rmIgnoresContainersThatDisappearDuringRemoval|rmSupportsForceAndAnonymousVolumeRemoval|rmConfirmsBeforeStoppingContainers|rmStopSkipsStopForAlreadyStoppedContainers'
}

# Run the local-only Docker Compose and container-compose parity check.
main() {
    parse_args "$@"
    check_docker
    create_fixture
    trap cleanup EXIT
    check_docker_compose_rm
    check_container_compose_rm_tests
    printf 'Docker Compose/container-compose rm parity check passed for project %s\n' "$PROJECT_NAME"
}

main "$@"
