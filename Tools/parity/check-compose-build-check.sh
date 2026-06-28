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
#   check-compose-build-check.sh [options]
#
# OPTIONS:
#   --strict       Fail when Docker Compose V2 or container-compose is unavailable.
#   -h, --help     Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#   CONTAINER_COMPOSE_BUILD_CHECK_LIVE
#                      Set to 1 to run live `container compose build --check`.
#                      This needs a matching forked container build backend.
#
# This script is intentionally local-only and is not part of CI. It reuses
# Docker Compose's upstream e2e build-test/minimal fixture, changes only the
# temporary Dockerfile's FROM casing to trigger BuildKit lint, checks Docker
# Compose V2 `build --check` behavior, verifies container-compose
# `build --print --check` renders a Buildx lint call, and can optionally run
# the live container-backed check when the matching forked runtime is installed.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
UPSTREAM_FIXTURES="$REPO_ROOT/.build/parity/docker-compose-e2e/pkg/e2e/fixtures/build-test/minimal"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""

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

# Print command usage from the top-of-file help block.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-build-check.sh/$SCRIPT_NAME/"
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

# Either fail in strict mode or skip the local-only parity check.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose build-check parity"
    exit 0
}

# Locate the Docker Compose V2 command to compare against.
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

# Verify required local tools and upstream Docker Compose fixtures.
check_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi

    if ! "$REPO_ROOT/Tools/parity/sync-docker-compose-e2e-fixtures.sh" --strict >/dev/null; then
        skip_or_fail 'Docker Compose e2e fixtures are not available'
    fi

    if [[ ! -f "$UPSTREAM_FIXTURES/compose.yaml" || ! -f "$UPSTREAM_FIXTURES/Dockerfile" ]]; then
        skip_or_fail "Docker Compose build-test/minimal fixture is missing from $UPSTREAM_FIXTURES"
    fi
}

# Copy the upstream Docker fixture and mutate only the temporary Dockerfile.
make_fixture() {
    local fixture="$1"
    cp -R "$UPSTREAM_FIXTURES"/. "$fixture"/
    python3 - "$fixture/Dockerfile" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("FROM scratch\n", "FROM scratch as base\n", 1)
path.write_text(text, encoding="utf-8")
PY
}

# Assert Docker Compose reports the expected BuildKit lint warning.
expect_docker_check_warning() {
    local fixture="$1"
    local output
    local status

    set +e
    output="$("${DOCKER_COMPOSE_COMMAND[@]}" --project-directory "$fixture" -f "$fixture/compose.yaml" build --check test 2>&1)"
    status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
        error "Docker Compose build --check succeeded; expected lint failure"
        printf '%s\n' "$output" >&2
        return 1
    fi
    if [[ "$output" != *"FromAsCasing"* ]]; then
        error "Docker Compose build --check did not report FromAsCasing"
        printf '%s\n' "$output" >&2
        return 1
    fi
}

# Assert container-compose prints Buildx bake lint JSON with no outputs.
expect_container_print_check_bake() {
    local fixture="$1"
    local output

    output="$("$CONTAINER_COMPOSE" --ansi never --project-directory "$fixture" -f "$fixture/compose.yaml" build --print --check test)"
    python3 - "$output" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
target = doc["target"]["test"]
if target.get("call") != "lint":
    raise SystemExit("container-compose build --print --check did not render call=lint")
if "output" in target:
    raise SystemExit("container-compose build --print --check rendered an output")
PY
}

# Optionally assert live fork-backed container-compose check behavior.
expect_container_live_check_warning() {
    local fixture="$1"
    local output
    local status

    set +e
    output="$("$CONTAINER_COMPOSE" --ansi never --project-directory "$fixture" -f "$fixture/compose.yaml" build --check test 2>&1)"
    status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
        error "container-compose build --check succeeded; expected lint failure"
        printf '%s\n' "$output" >&2
        return 1
    fi
    if [[ "$output" != *"FromAsCasing"* && "$output" != *"build check failed"* ]]; then
        error "container-compose build --check did not report lint failure"
        printf '%s\n' "$output" >&2
        return 1
    fi
}

# Run the parity workflow.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools

    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-build-check.XXXXXX")"
    trap 'rm -rf "$FIXTURE_DIR"' EXIT
    make_fixture "$FIXTURE_DIR"

    expect_docker_check_warning "$FIXTURE_DIR"
    expect_container_print_check_bake "$FIXTURE_DIR"

    if [[ "${CONTAINER_COMPOSE_BUILD_CHECK_LIVE:-0}" == "1" ]]; then
        expect_container_live_check_warning "$FIXTURE_DIR"
    else
        warning 'live container-compose build --check skipped; set CONTAINER_COMPOSE_BUILD_CHECK_LIVE=1 with the matching forked container backend to enable'
    fi

    info 'Docker Compose build-check parity passed.'
}

main "$@"
