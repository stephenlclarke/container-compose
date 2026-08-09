#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright (c) 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-deploy-job-modes.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It compares
# Docker Compose local-mode handling of replicated-job and global-job services
# with container-compose: both modes preserve normal restart-policy projection,
# detached up returns while the containers are running, and up --wait uses
# ordinary running/healthy readiness rather than job-completion waiting.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""
DOCKER_PROJECT="cc-deploy-jobs-docker-${RANDOM}-$$"
CONTAINER_PROJECT="cc-deploy-jobs-container-${RANDOM}-$$"

# Print an informational line.
info() {
    printf '%s\n' "$*"
}

# Print a warning line.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error line.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Show usage extracted from the top-of-file help block.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-deploy-job-modes.sh/$SCRIPT_NAME/"
}

# Parse command-line options.
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

# Exit cleanly for unavailable optional local tools, or fail when strict.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose deploy-job-mode parity check"
    exit 0
}

# Resolve Docker Compose as either a plugin or a standalone binary.
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

# Verify the exact local tools the check will exercise.
check_tools() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker daemon is not available'
    fi
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi
}

# Create the one fixture used by the Docker oracle and the candidate CLI.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-deploy-jobs.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  replicated:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 30"]
    deploy:
      mode: replicated-job
      restart_policy:
        condition: on-failure
        max_attempts: 3
  global:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 30"]
    restart: unless-stopped
    deploy:
      mode: global-job
YAML
}

# Remove only the uniquely named local projects and temporary fixture root.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$FIXTURE_DIR/compose.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        "$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/compose.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert Docker Compose config preserves job modes and restart metadata.
assert_docker_config() {
    local config_output="$1"

    python3 - "$config_output" <<'PY'
import json
import pathlib
import sys

services = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["services"]
replicated = services["replicated"]
global_service = services["global"]
if replicated.get("deploy", {}).get("mode") != "replicated-job":
    raise SystemExit("Docker Compose did not preserve replicated-job mode")
restart_policy = replicated.get("deploy", {}).get("restart_policy", {})
if (restart_policy.get("condition"), restart_policy.get("max_attempts")) != ("on-failure", 3):
    raise SystemExit(f"Docker Compose replicated restart policy was {restart_policy!r}")
if global_service.get("deploy", {}).get("mode") != "global-job":
    raise SystemExit("Docker Compose did not preserve global-job mode")
if global_service.get("restart") != "unless-stopped":
    raise SystemExit(f"Docker Compose global restart was {global_service.get('restart')!r}")
PY
}

# Assert container-compose config retains the same parsed Compose semantics.
assert_container_config() {
    local config_output="$1"

    python3 - "$config_output" <<'PY'
import json
import pathlib
import sys

services = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["services"]
replicated = services["replicated"]
global_service = services["global"]
if replicated.get("deployMode") != "replicated-job":
    raise SystemExit(f"container-compose replicated mode was {replicated.get('deployMode')!r}")
restart_policy = replicated.get("deployRestartPolicy") or {}
if (restart_policy.get("condition"), restart_policy.get("maxAttempts")) != ("on-failure", 3):
    raise SystemExit(f"container-compose replicated restart policy was {restart_policy!r}")
if global_service.get("deployMode") != "global-job":
    raise SystemExit(f"container-compose global mode was {global_service.get('deployMode')!r}")
if global_service.get("restart") != "unless-stopped":
    raise SystemExit(f"container-compose global restart was {global_service.get('restart')!r}")
PY
}

# Assert a Docker service is running with the requested HostConfig policy.
assert_docker_service() {
    local project="$1"
    local service="$2"
    local expected_policy="$3"
    local expected_attempts="$4"
    local container_id

    container_id="$("${DOCKER_COMPOSE_COMMAND[@]}" -p "$project" -f "$FIXTURE_DIR/compose.yml" ps -q "$service")"
    if [[ -z "$container_id" ]]; then
        error "Docker Compose did not create service $service"
        return 1
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" != 'true' ]]; then
        error "Docker Compose service $service is not running"
        return 1
    fi
    python3 - "$container_id" "$expected_policy" "$expected_attempts" <<'PY'
import json
import subprocess
import sys

container_id, expected_policy, expected_attempts = sys.argv[1:]
payload = json.loads(subprocess.check_output(["docker", "inspect", container_id], text=True))[0]
policy = payload["HostConfig"]["RestartPolicy"]
actual = (policy.get("Name"), int(policy.get("MaximumRetryCount") or 0))
expected = (expected_policy, int(expected_attempts))
if actual != expected:
    raise SystemExit(f"Docker restart policy for {container_id} was {actual!r}, want {expected!r}")
PY
}

# Exercise the pinned behavior surface through Docker Compose and Docker.
expect_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --format json >"$config_output"
    assert_docker_config "$config_output"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$FIXTURE_DIR/compose.yml" up --detach >/dev/null
    assert_docker_service "$DOCKER_PROJECT" replicated on-failure 3
    assert_docker_service "$DOCKER_PROJECT" global unless-stopped 0
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$FIXTURE_DIR/compose.yml" down --volumes --remove-orphans >/dev/null

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$FIXTURE_DIR/compose.yml" up --wait --wait-timeout 5 >/dev/null
    assert_docker_service "$DOCKER_PROJECT" replicated on-failure 3
    assert_docker_service "$DOCKER_PROJECT" global unless-stopped 0
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$FIXTURE_DIR/compose.yml" down --volumes --remove-orphans >/dev/null
}

# Exercise the same semantics through the container-compose CLI dry-run path.
expect_container_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local detached_output="$FIXTURE_DIR/container-compose-detached.txt"
    local wait_output="$FIXTURE_DIR/container-compose-wait.txt"

    "$CONTAINER_COMPOSE" --ansi never --project-directory "$FIXTURE_DIR" -p "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/compose.yml" config --format json >"$config_output"
    assert_container_config "$config_output"

    if ! "$CONTAINER_COMPOSE" --ansi never --dry-run --project-directory "$FIXTURE_DIR" -p "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/compose.yml" up --detach >"$detached_output" 2>&1; then
        error 'container-compose rejected Docker-compatible deploy job modes during detached up'
        sed -n '1,160p' "$detached_output" >&2
        return 1
    fi
    for service in replicated global; do
        if ! grep -F -- "container run --name $CONTAINER_PROJECT-$service-1 --detach" "$detached_output" >/dev/null; then
            error "container-compose did not plan detached startup for $service"
            sed -n '1,160p' "$detached_output" >&2
            return 1
        fi
    done
    if ! grep -F -- '--restart on-failure:3' "$detached_output" >/dev/null || ! grep -F -- '--restart unless-stopped' "$detached_output" >/dev/null; then
        error 'container-compose did not plan the ordinary Docker restart policies for deploy jobs'
        sed -n '1,160p' "$detached_output" >&2
        return 1
    fi
    if grep -F -- '+ container wait ' "$detached_output" >/dev/null; then
        error 'container-compose still plans a job-completion wait during detached up'
        sed -n '1,160p' "$detached_output" >&2
        return 1
    fi

    if ! "$CONTAINER_COMPOSE" --ansi never --dry-run --project-directory "$FIXTURE_DIR" -p "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/compose.yml" up --wait --wait-timeout 5 >"$wait_output" 2>&1; then
        error 'container-compose rejected Docker-compatible deploy job modes during up --wait'
        sed -n '1,160p' "$wait_output" >&2
        return 1
    fi
    for service in replicated global; do
        if ! grep -F -- "+ compose-runtime wait-ready --timeout 5 $CONTAINER_PROJECT-$service-1" "$wait_output" >/dev/null; then
            error "container-compose did not apply ordinary wait readiness to $service"
            sed -n '1,160p' "$wait_output" >&2
            return 1
        fi
    done
    if grep -F -- '+ container wait ' "$wait_output" >/dev/null; then
        error 'container-compose still plans a job-completion wait for up --wait'
        sed -n '1,160p' "$wait_output" >&2
        return 1
    fi
}

# Run the local Docker oracle and the candidate CLI check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT

    expect_docker_behavior
    expect_container_behavior

    info 'Docker Compose deploy job mode parity passed.'
}

main "$@"
