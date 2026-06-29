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
#   check-compose-up-menu.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker daemon, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It verifies
# Docker Compose V2 and container-compose both accept the supported
# `up --menu` optional-boolean forms against a compose.yml fixture, and it
# keeps the current container-compose exit-control/watch menu boundaries
# documented as expected Docker differences.

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
LAST_STDOUT_FILE=""
LAST_STDERR_FILE=""
PROJECT_NAME="cc-up-menu-$RANDOM"

# Print an informational message to stdout.
info() {
    printf '%s\n' "$*"
}

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-up-menu.sh/$SCRIPT_NAME/"
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

# Either fail in strict mode or skip the optional local-only parity check.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose up-menu parity check"
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

# Check local tools needed by the comparison.
check_tools() {
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi

    if ! "$CONTAINER_COMPOSE" version --short >/dev/null 2>&1; then
        skip_or_fail "container-compose binary could not run: $CONTAINER_COMPOSE"
    fi

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker daemon is not available for Docker Compose up dry-run checks'
    fi
}

# Create a compose.yml fixture that includes a develop.watch surface.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-up-menu.XXXXXX")"
    mkdir -p "$FIXTURE_DIR/src"
    printf '%s\n' \
        'services:' \
        '  api:' \
        '    image: alpine:3.20' \
        '    develop:' \
        '      watch:' \
        '        - action: sync' \
        '          path: ./src' \
        '          target: /app/src' \
        >"$FIXTURE_DIR/compose.yml"
}

# Remove temporary fixture files and Docker objects.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        rm -rf "$FIXTURE_DIR"
    fi
}

# Run a command and assert its exit status.
expect_status() {
    local label="$1"
    local expected="$2"
    shift 2

    local index
    index="$(printf '%03d' "$RANDOM")"
    LAST_STDOUT_FILE="$FIXTURE_DIR/$index.stdout"
    LAST_STDERR_FILE="$FIXTURE_DIR/$index.stderr"

    set +e
    "$@" >"$LAST_STDOUT_FILE" 2>"$LAST_STDERR_FILE"
    local status=$?
    set -e

    if [[ "$status" -ne "$expected" ]]; then
        error "$label exited $status, expected $expected"
        if [[ -s "$LAST_STDERR_FILE" ]]; then
            sed -n '1,80p' "$LAST_STDERR_FILE" >&2
        fi
        if [[ -s "$LAST_STDOUT_FILE" ]]; then
            sed -n '1,80p' "$LAST_STDOUT_FILE" >&2
        fi
        return 1
    fi
}

# Assert a captured file includes expected text.
assert_file_contains() {
    local path="$1"
    local expected="$2"

    if ! grep -F "$expected" "$path" >/dev/null; then
        error "expected $path to contain: $expected"
        sed -n '1,80p' "$path" >&2
        return 1
    fi
}

# Assert Docker Compose and container-compose both accept supported menu forms.
check_supported_menu_forms() {
    expect_status 'Docker Compose accepts --menu=false --no-start' 0 \
        "${DOCKER_COMPOSE_COMMAND[@]}" --ansi never -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" \
        --dry-run up --menu=false --no-start api

    expect_status 'container-compose accepts --menu=false --no-start' 0 \
        "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" \
        --dry-run up --menu=false --no-start api
    assert_file_contains "$LAST_STDOUT_FILE" "container create --name $PROJECT_NAME-api-1"

    expect_status 'Docker Compose accepts --menu=true --no-start' 0 \
        "${DOCKER_COMPOSE_COMMAND[@]}" --ansi never -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" \
        --dry-run up --menu=true --no-start api

    expect_status 'container-compose accepts --menu=true --no-start without a TTY' 0 \
        "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" \
        --dry-run up --menu=true --no-start api
    assert_file_contains "$LAST_STDOUT_FILE" "container create --name $PROJECT_NAME-api-1"

    expect_status 'Docker Compose lets --menu=false override COMPOSE_MENU' 0 \
        env COMPOSE_MENU=true "${DOCKER_COMPOSE_COMMAND[@]}" --ansi never -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" \
        --dry-run up --menu=false --no-start api

    expect_status 'container-compose lets --menu=false override COMPOSE_MENU' 0 \
        env COMPOSE_MENU=true "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" \
        --dry-run up --menu=false --no-start api
    assert_file_contains "$LAST_STDOUT_FILE" "container create --name $PROJECT_NAME-api-1"
}

# Check the currently documented Docker differences for combined menu modes.
check_documented_boundaries() {
    expect_status 'Docker Compose accepts --menu with exit-control dry-run' 0 \
        "${DOCKER_COMPOSE_COMMAND[@]}" --ansi never -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" \
        --dry-run up --menu --abort-on-container-exit api

    expect_status 'container-compose documents --menu with exit-control as unsupported' 1 \
        "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" \
        --dry-run up --menu --abort-on-container-exit api
    assert_file_contains "$LAST_STDERR_FILE" 'unsupported compose feature: up --menu with exit-control options'

    expect_status 'Docker Compose accepts --menu with --watch dry-run' 0 \
        "${DOCKER_COMPOSE_COMMAND[@]}" --ansi never -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" \
        --dry-run up --menu --watch api

    expect_status 'container-compose documents --menu with --watch as unsupported' 1 \
        "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" \
        --dry-run up --menu --watch api
    assert_file_contains "$LAST_STDERR_FILE" 'unsupported compose feature: up --menu cannot be combined with --watch yet'
}

# Run the local-only Docker Compose V2 parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT

    check_supported_menu_forms
    check_documented_boundaries

    info 'Docker Compose up-menu parity passed with documented exit-control/watch differences.'
}

main "$@"
