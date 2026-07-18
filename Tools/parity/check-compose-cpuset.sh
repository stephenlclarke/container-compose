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
#   check-compose-cpuset.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or container-compose is unavailable.
#               Docker Engine dry-run confirmation is performed when a daemon
#               is available; Compose config parity is always required.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script verifies that Docker Compose V2 accepts a `cpuset` value, then
# checks that container-compose carries it into the generic runtime argument.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
DOCKER_COMPOSE_COMMAND=()
DOCKER_DAEMON_AVAILABLE=0
FIXTURE_DIR=""
PROJECT_NAME="cc-cpuset-$RANDOM"

# Prints an informational message.
info() { printf '%s\n' "$*"; }

# Prints a warning message to standard error.
warning() { printf 'warning: %s\n' "$*" >&2; }

# Prints an error message to standard error.
error() { printf 'error: %s\n' "$*" >&2; }

# Displays the supported command-line options.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-cpuset.sh/$SCRIPT_NAME/"
}

# Parses command-line options.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict) STRICT=1; shift ;;
            -h | --help) usage; exit 0 ;;
            *) error "unknown argument: $1"; usage >&2; return 2 ;;
        esac
    done
}

# Stops or skips according to strict-mode policy.
skip_or_fail() {
    local message="$1"
    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    warning "$message; skipping Docker Compose CPU-set parity check"
    exit 0
}

# Finds a Docker Compose V2 command.
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

# Checks the local parity-tool prerequisites.
check_tools() {
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is not available'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
}

# Detects whether Docker Engine dry-run validation is available.
detect_docker_daemon() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        DOCKER_DAEMON_AVAILABLE=1
        return
    fi
    info 'Docker daemon unavailable; checking Docker Compose config parity without Engine dry-run output.'
}

# Creates the Compose fixture used for the comparison.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-cpuset.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: alpine:3.20
    cpuset: "0-1"
YAML
}

# Removes the temporary Compose fixture.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Confirms Docker Compose retains the CPU-set value in normalized config.
assert_docker_config_preserves_cpuset() {
    python3 - "$1" <<'PY'
import json
import pathlib
import sys

service = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("services", {}).get("api", {})
cpuset = service.get("cpuset")
if cpuset != "0-1":
    raise SystemExit(f"Docker Compose cpuset = {cpuset!r}, want '0-1'")
PY
}

# Confirms container-compose retains the CPU-set value in normalized config.
assert_container_config_preserves_cpuset() {
    python3 - "$1" <<'PY'
import json
import pathlib
import sys

service = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("services", {}).get("api", {})
cpuset = service.get("cpuset")
if cpuset != "0-1":
    raise SystemExit(f"container-compose cpuset = {cpuset!r}, want '0-1'")
PY
}

# Confirms the local dry-run contains the expected generic runtime flag.
dry_run_projects_cpuset() {
    local output_path="$1"
    grep -F -- '--cpuset-cpus 0-1' "$output_path" >/dev/null
}

# Validates Docker Compose config and, when possible, Engine dry-run behavior.
expect_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"
    local dry_run_output="$FIXTURE_DIR/docker-compose-dry-run.txt"
    "${DOCKER_COMPOSE_COMMAND[@]}" --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --format json >"$config_output"
    assert_docker_config_preserves_cpuset "$config_output"
    if ((DOCKER_DAEMON_AVAILABLE == 0)); then return; fi
    "${DOCKER_COMPOSE_COMMAND[@]}" --ansi never --dry-run --project-directory "$FIXTURE_DIR" -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" up --no-start api >"$dry_run_output" 2>&1
    if ! grep -F "Container $PROJECT_NAME-api-1 Created" "$dry_run_output" >/dev/null; then
        error 'Docker Compose did not accept cpuset in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
}

# Validates container-compose config and dry-run behavior.
expect_container_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local dry_run_output="$FIXTURE_DIR/container-compose-dry-run.txt"
    "$CONTAINER_COMPOSE" --ansi never --project-directory "$FIXTURE_DIR" -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" config --format json >"$config_output"
    assert_container_config_preserves_cpuset "$config_output"
    "$CONTAINER_COMPOSE" --ansi never --dry-run --project-directory "$FIXTURE_DIR" -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" up --no-start api >"$dry_run_output" 2>&1
    if ! grep -F "container create --name $PROJECT_NAME-api-1" "$dry_run_output" >/dev/null; then
        error 'container-compose did not accept cpuset in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
    if ! dry_run_projects_cpuset "$dry_run_output"; then
        error 'container-compose did not project cpuset to --cpuset-cpus in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
}

# Runs the complete CPU-set parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    detect_docker_daemon
    create_fixture
    trap cleanup EXIT
    expect_docker_behavior
    expect_container_behavior
    info 'Docker Compose config and container-compose CPU-set parity passed.'
}

main "$@"
