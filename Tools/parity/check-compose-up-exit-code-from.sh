#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
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
#   check-compose-up-exit-code-from.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE       Path to the container-compose binary. Defaults to
#                           the local SwiftPM debug build at .build/debug/compose.
#   CONTAINER_COMPOSE_CONTAINER
#                           Runtime CLI used for matching live macOS validation.
#                           Defaults to container from PATH.
#   CONTAINER_COMPOSE_LIVE  Set to 1 when an isolated matching Apple runtime is
#                           running. The check then proves container-compose
#                           returns Docker Compose V2's selected exit status.
#   DOCKER_COMPOSE          Docker Compose command to compare with. Defaults to
#                           "docker compose" when available, otherwise docker-compose.
#
# This local parity check proves Docker Compose V2 returns the selected
# service's terminal status for `up --exit-code-from`, and verifies the same
# result on an isolated matching Apple runtime when requested.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_DIR="$REPO_ROOT/Tools/parity/fixtures/up-exit-code-from"
readonly COMPOSE_FILE="$FIXTURE_DIR/compose.yaml"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
DOCKER_COMPOSE_COMMAND=()
DOCKER_PROJECT_NAME="container-compose-up-exit-code-from-docker-$RANDOM-$$"
CONTAINER_PROJECT_NAME="container-compose-up-exit-code-from-runtime-$RANDOM-$$"
WORK_DIR=""

# Print an informational message to stdout.
info() {
    printf '%s\n' "$*"
}

# Print a warning to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print usage extracted from the script header.
usage() {
    sed -n '/^# USAGE:/,/^# This local parity/ { /^# This local parity/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-up-exit-code-from.sh/$SCRIPT_NAME/"
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

# Skip an optional local check, or fail when strict validation was requested.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping up --exit-code-from parity check"
    exit 0
}

# Locate Docker Compose V2 in plugin or standalone form.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
        "${DOCKER_COMPOSE_COMMAND[@]}" version >/dev/null 2>&1 \
            || skip_or_fail "Docker Compose V2 command is unavailable: $DOCKER_COMPOSE"
        return
    fi
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
        return
    fi
    if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
        return
    fi
    skip_or_fail 'Docker Compose V2 is not available'
}

# Ensure the reference engine, local plugin, and checked-in fixture are ready.
check_tools() {
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is not available'
    command -v docker >/dev/null 2>&1 || skip_or_fail 'docker is not available'
    docker info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is not available'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    [[ -f "$COMPOSE_FILE" ]] || { error "missing up exit-code-from fixture: $COMPOSE_FILE"; return 1; }
}

# Create an isolated directory for captured command output.
prepare_work_dir() {
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-compose-up-exit-code-from.XXXXXX")"
}

# Remove only this parity slice's resources and temporary command captures.
cleanup() {
    if ((${#DOCKER_COMPOSE_COMMAND[@]} > 0)); then
        "${DOCKER_COMPOSE_COMMAND[@]}" \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$DOCKER_PROJECT_NAME" \
            --file "$COMPOSE_FILE" \
            down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        down --volumes --remove-orphans >/dev/null 2>&1 || true
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

# Capture a command and compare its actual status with the Docker Compose contract.
expect_status() {
    local label="$1"
    local expected_status="$2"
    local output_file="$3"
    shift 3

    set +e
    "$@" >"$output_file" 2>&1
    local actual_status=$?
    set -e

    if ((actual_status != expected_status)); then
        error "$label exited $actual_status, expected $expected_status"
        sed -n '1,160p' "$output_file" >&2
        return 1
    fi
}

# Validate the resolved fixture keeps the selected terminal exit code contract.
assert_config() {
    local implementation="$1"
    local config_file="$2"

    python3 - "$implementation" "$config_file" <<'PY'
import json
import pathlib
import sys

implementation, config_file = sys.argv[1:3]
model = json.loads(pathlib.Path(config_file).read_text(encoding="utf-8"))
services = model.get("services", {})
api = services.get("api", {})
db = services.get("db", {})

if api.get("command") != ["sh", "-c", "exit 7"]:
    raise SystemExit(f"{implementation}: api command is not the selected exit-7 fixture: {api.get('command')!r}")
if db.get("command") != ["sh", "-c", "sleep 60"]:
    raise SystemExit(f"{implementation}: db command is not the running dependency fixture: {db.get('command')!r}")
depends_on = api.get("depends_on", api.get("dependsOn", {}))
if depends_on.get("db", {}).get("condition") != "service_started":
    raise SystemExit(f"{implementation}: api does not retain its db start dependency: {depends_on!r}")
PY
}

# Compare normalized Docker Compose and container-compose fixture models.
check_config_parity() {
    local docker_config="$WORK_DIR/docker-compose-config.json"
    local container_config="$WORK_DIR/container-compose-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json >"$docker_config"
    assert_config 'Docker Compose V2' "$docker_config"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json >"$container_config"
    assert_config 'container-compose' "$container_config"
}

# Prove Docker Compose V2 returns the terminal status of the selected service.
check_docker_compose_status() {
    expect_status 'Docker Compose V2 up --exit-code-from api' 7 "$WORK_DIR/docker-compose-up.log" \
        "${DOCKER_COMPOSE_COMMAND[@]}" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        up --exit-code-from api api
}

# Prove the matching Apple runtime returns the Docker Compose V2 selected status.
check_container_compose_status() {
    if [[ "$CONTAINER_COMPOSE_LIVE" != "1" ]]; then
        info 'live Apple runtime validation not requested; Docker Compose V2 reference and model parity passed'
        return
    fi
    if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        error "matching Apple runtime binary is unavailable: $CONTAINER_BINARY"
        return 1
    fi
    "$CONTAINER_BINARY" system status >/dev/null

    expect_status 'container-compose up --exit-code-from api' 7 "$WORK_DIR/container-compose-up.log" \
        env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        up --exit-code-from api api
}

# Run the local Docker Compose V2 and optional matching-Apple-runtime checks.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    prepare_work_dir
    trap cleanup EXIT

    check_config_parity
    check_docker_compose_status
    check_container_compose_status

    info 'Docker Compose up --exit-code-from parity passed.'
}

main "$@"
