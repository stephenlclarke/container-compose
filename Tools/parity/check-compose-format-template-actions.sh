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
#   check-compose-format-template-actions.sh [options]
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
# This script keeps Docker Compose V2 and container-compose aligned for the
# documented row-template actions used by `ps`: `upper`, `truncate`, `json`,
# `split`, and `join` with a parenthesized nested expression. It deliberately
# uses Compose-generated fields instead of image references because runtimes
# may canonicalize equivalent image names differently.

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
DOCKER_PROJECT="cc-format-docker-$RANDOM"
CONTAINER_PROJECT="cc-format-container-$RANDOM"

# Writes a normal progress line.
info() {
    printf '%s\n' "$*"
}

# Writes a recoverable warning to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Writes a failure message to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Prints command usage from the header.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-format-template-actions.sh/$SCRIPT_NAME/"
}

# Parses script arguments.
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

# Skips a missing optional dependency unless strict mode requires it.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose format-template parity check"
    exit 0
}

# Chooses a usable Docker Compose V2 command.
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

# Verifies that both comparison commands can run.
check_tools() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker Engine is not available'
    fi
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Creates the isolated Compose project fixture.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-format-template-actions.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["sleep", "120"]
YAML
}

# Removes only the isolated fixture and its two generated projects.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" -f "$FIXTURE_DIR/compose.yml" \
            down --remove-orphans --volumes >/dev/null 2>&1 || true
        "$CONTAINER_COMPOSE" --project-name "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/compose.yml" \
            down --remove-orphans --volumes >/dev/null 2>&1 || true
        rm -rf "$FIXTURE_DIR"
    fi
}

# Compares one formatter result with its expected value.
assert_equal() {
    local actual="$1"
    local expected="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'actual:   %q\nexpected: %q\n' "$actual" "$expected" >&2
        error "$label did not match Docker Compose V2"
        return 1
    fi
}

# Runs the shared ps template against one Compose implementation.
template_output() {
    local project="$1"
    shift
    "$@" --project-name "$project" -f "$FIXTURE_DIR/compose.yml" ps \
        --format '{{upper .Service}}\t{{truncate .Name 6}}\t{{json .Name}}\t{{join (split .Name "-") "/"}}'
}

# Starts both fixtures and checks their formatted ps rows.
run_checks() {
    local docker_output container_output expected name
    name="$DOCKER_PROJECT-api-1"
    expected="API"$'\t'"cc-for"$'\t'"\"$name\""$'\t'"${name//-/\/}"
    "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" -f "$FIXTURE_DIR/compose.yml" up --detach >/dev/null
    docker_output="$(template_output "$DOCKER_PROJECT" "${DOCKER_COMPOSE_COMMAND[@]}")"
    assert_equal "$docker_output" "$expected" 'Docker Compose ps template'

    name="$CONTAINER_PROJECT-api-1"
    expected="API"$'\t'"cc-for"$'\t'"\"$name\""$'\t'"${name//-/\/}"
    "$CONTAINER_COMPOSE" --project-name "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/compose.yml" up --detach >/dev/null
    container_output="$(template_output "$CONTAINER_PROJECT" "$CONTAINER_COMPOSE")"
    assert_equal "$container_output" "$expected" 'container-compose ps template'
}

# Runs the parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT
    run_checks
    info 'Docker Compose format-template action parity passed.'
}

main "$@"
