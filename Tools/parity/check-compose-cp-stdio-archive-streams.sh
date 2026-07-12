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
#   check-compose-cp-stdio-archive-streams.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, container-compose,
#               or the Apple container runtime is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   CONTAINER_COMPOSE_CONTAINER
#                      Path to the Apple container binary used by container-compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It verifies
# Docker Compose V2 and container-compose `cp -` archive stream behavior for
# stdin-to-service and service-to-stdout copies.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""
DOCKER_PROJECT_NAME="container-compose-cp-stdio-docker-$RANDOM-$$"
CONTAINER_PROJECT_NAME="container-compose-cp-stdio-runtime-$RANDOM-$$"

info() {
    printf '%s\n' "$*"
}

warning() {
    printf 'warning: %s\n' "$*" >&2
}

error() {
    printf 'error: %s\n' "$*" >&2
}

usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-cp-stdio-archive-streams.sh/$SCRIPT_NAME/"
}

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

skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker/container-compose cp stdio archive parity check"
    exit 0
}

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

check_tools() {
    detect_docker_compose
    if ! command -v tar >/dev/null 2>&1; then
        skip_or_fail 'tar is not available'
    fi
    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker Engine is not available'
    fi
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
    if ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1 && [[ ! -x "$CONTAINER_BINARY" ]]; then
        skip_or_fail "container binary is not executable: $CONTAINER_BINARY"
    fi
}

create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-cp-stdio.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  app:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 120"]
YAML
    printf 'from stdin archive\n' >"$FIXTURE_DIR/payload.txt"
    tar -C "$FIXTURE_DIR" -cf "$FIXTURE_DIR/payload.tar" payload.txt
    printf 'from stdout archive\n' >"$FIXTURE_DIR/stdout-source.txt"
}

cleanup() {
    local status=$?

    if [[ -n "$FIXTURE_DIR" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" down --remove-orphans >/dev/null 2>&1 || true
        CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
            "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" down --remove-orphans >/dev/null 2>&1 || true
        rm -rf "$FIXTURE_DIR"
    fi

    exit "$status"
}

assert_file_equals() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if ! cmp -s "$expected" "$actual"; then
        error "$label did not match expected content"
        printf 'expected:\n' >&2
        cat "$expected" >&2
        printf '\nactual:\n' >&2
        cat "$actual" >&2
        return 1
    fi
}

extract_stdout_archive() {
    local archive="$1"
    local destination="$2"

    mkdir -p "$destination"
    tar -C "$destination" -xf "$archive"
}

check_docker_compose_cp_streams() {
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" up -d --quiet-pull app >/dev/null
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp - app:/tmp <"$FIXTURE_DIR/payload.tar"
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp app:/tmp/payload.txt "$FIXTURE_DIR/docker-payload.txt"
    assert_file_equals "$FIXTURE_DIR/payload.txt" "$FIXTURE_DIR/docker-payload.txt" "Docker Compose stdin archive copy"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp "$FIXTURE_DIR/stdout-source.txt" app:/tmp/stdout-source.txt
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp app:/tmp/stdout-source.txt - >"$FIXTURE_DIR/docker-stdout.tar"
    extract_stdout_archive "$FIXTURE_DIR/docker-stdout.tar" "$FIXTURE_DIR/docker-stdout"
    assert_file_equals "$FIXTURE_DIR/stdout-source.txt" "$FIXTURE_DIR/docker-stdout/stdout-source.txt" "Docker Compose stdout archive copy"
}

check_container_compose_cp_streams() {
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" up -d app >/dev/null
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp - app:/tmp <"$FIXTURE_DIR/payload.tar"
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp app:/tmp/payload.txt "$FIXTURE_DIR/container-payload.txt"
    assert_file_equals "$FIXTURE_DIR/payload.txt" "$FIXTURE_DIR/container-payload.txt" "container-compose stdin archive copy"

    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp "$FIXTURE_DIR/stdout-source.txt" app:/tmp/stdout-source.txt
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp app:/tmp/stdout-source.txt - >"$FIXTURE_DIR/container-stdout.tar"
    extract_stdout_archive "$FIXTURE_DIR/container-stdout.tar" "$FIXTURE_DIR/container-stdout"
    assert_file_equals "$FIXTURE_DIR/stdout-source.txt" "$FIXTURE_DIR/container-stdout/stdout-source.txt" "container-compose stdout archive copy"
}

main() {
    parse_args "$@"
    check_tools
    trap cleanup EXIT
    create_fixture
    check_docker_compose_cp_streams
    check_container_compose_cp_streams
    info 'Docker Compose cp stdio archive parity check passed for stdin and stdout tar streams.'
}

main "$@"
