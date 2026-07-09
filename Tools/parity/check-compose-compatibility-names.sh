#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright (c) 2026 container-compose project authors.
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
#   check-compose-compatibility-names.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script verifies Docker Compose V2 root --compatibility behavior for
# generated service and one-off run container names, then checks that
# container-compose renders the same hyphen/underscore separator choices.

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
PROJECT_NAME="cccompat$RANDOM"

# Print an informational line to stdout.
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

# Show usage extracted from the top-of-file help block.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-compatibility-names.sh/$SCRIPT_NAME/"
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

# Skip optional parity checks, or fail when strict mode is active.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose compatibility-name parity check"
    exit 0
}

# Resolve the Docker Compose command used as the parity oracle.
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

# Ensure required local tools are available.
check_tools() {
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create a minimal Compose fixture with a replicated service and one-off job.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-compat-names.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: alpine
    scale: 2
  job:
    image: alpine
YAML
}

# Capture command output without failing on Docker Compose dry-run run exits.
capture_output() {
    local output
    set +e
    output="$("$@" 2>&1)"
    set -e
    printf '%s\n' "$output"
}

# Assert that a rendered output contains the expected name fragment.
assert_contains() {
    local output="$1"
    local expected="$2"
    local label="$3"

    if [[ "$output" != *"$expected"* ]]; then
        printf '%s\n' "$output" >&2
        error "$label did not contain expected fragment: $expected"
        return 1
    fi
}

# Assert that a rendered output does not contain an incompatible name fragment.
assert_not_contains() {
    local output="$1"
    local unexpected="$2"
    local label="$3"

    if [[ "$output" == *"$unexpected"* ]]; then
        printf '%s\n' "$output" >&2
        error "$label contained unexpected fragment: $unexpected"
        return 1
    fi
}

# Run Docker Compose and container-compose name-separator checks.
run_checks() {
    local compose_file="$FIXTURE_DIR/compose.yml"
    local docker_default docker_compat docker_run_compat
    local container_default container_compat container_run_compat

    docker_default="$(capture_output "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$PROJECT_NAME" --dry-run -f "$compose_file" up --no-start)"
    docker_compat="$(capture_output "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$PROJECT_NAME" --compatibility --dry-run -f "$compose_file" up --no-start)"
    docker_run_compat="$(capture_output "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$PROJECT_NAME" --compatibility --dry-run -f "$compose_file" run --no-TTY job true)"

    assert_contains "$docker_default" "${PROJECT_NAME}-api-1" 'Docker Compose default up'
    assert_contains "$docker_default" "${PROJECT_NAME}-api-2" 'Docker Compose default up'
    assert_contains "$docker_compat" "${PROJECT_NAME}_api_1" 'Docker Compose compatibility up'
    assert_contains "$docker_compat" "${PROJECT_NAME}_api_2" 'Docker Compose compatibility up'
    assert_not_contains "$docker_compat" "${PROJECT_NAME}-api-1" 'Docker Compose compatibility up'
    assert_contains "$docker_run_compat" "${PROJECT_NAME}_job_run_" 'Docker Compose compatibility run'

    container_default="$(capture_output "$CONTAINER_COMPOSE" --project-name "$PROJECT_NAME" --dry-run -f "$compose_file" up --no-start)"
    container_compat="$(capture_output "$CONTAINER_COMPOSE" --project-name "$PROJECT_NAME" --compatibility --dry-run -f "$compose_file" up --no-start)"
    container_run_compat="$(capture_output "$CONTAINER_COMPOSE" --project-name "$PROJECT_NAME" --compatibility --dry-run -f "$compose_file" run --no-TTY job true)"

    assert_contains "$container_default" "${PROJECT_NAME}-api-1" 'container-compose default up'
    assert_contains "$container_default" "${PROJECT_NAME}-api-2" 'container-compose default up'
    assert_contains "$container_compat" "${PROJECT_NAME}_api_1" 'container-compose compatibility up'
    assert_contains "$container_compat" "${PROJECT_NAME}_api_2" 'container-compose compatibility up'
    assert_not_contains "$container_compat" "${PROJECT_NAME}-api-1" 'container-compose compatibility up'
    assert_contains "$container_run_compat" "${PROJECT_NAME}_job_run_" 'container-compose compatibility run'
}

# Remove temporary files created for this parity check.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Main entry point.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT
    run_checks
    info 'Docker Compose compatibility-name parity passed.'
}

main "$@"
