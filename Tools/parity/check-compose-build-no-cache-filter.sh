#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-build-no-cache-filter.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE       Path to the container-compose binary. Defaults to
#                           the local SwiftPM debug build at .build/debug/compose.
#   CONTAINER_COMPOSE_NORMALIZER
#                           Path to the matching compose-normalizer binary.
#                           Defaults to Tools/compose-normalizer/compose-normalizer.
#   CONTAINER_COMPOSE_CONTAINER
#                           Runtime CLI used for matching live macOS validation.
#                           Defaults to container from PATH.
#   CONTAINER_COMPOSE_LIVE  Set to 1 when an isolated matching Apple runtime is
#                           running. The check then proves live filtered rebuilds.
#   DOCKER_COMPOSE          Docker Compose command to compare with. Defaults to
#                           "docker compose" when available, otherwise docker-compose.
#
# This parity check proves config preservation, Buildx bake rendering, and
# named-stage cache invalidation against Docker Compose V2 and, when requested,
# the matching Apple runtime.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_DIR="$REPO_ROOT/Tools/parity/fixtures/build-no-cache-filter"
readonly COMPOSE_FILE="$FIXTURE_DIR/compose.yaml"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_COMPOSE_NORMALIZER="${CONTAINER_COMPOSE_NORMALIZER:-$REPO_ROOT/Tools/compose-normalizer/compose-normalizer}"
export CONTAINER_COMPOSE_NORMALIZER
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
DOCKER_COMPOSE_COMMAND=()
DOCKER_PROJECT_NAME="compose-no-cache-docker-$RANDOM-$$"
CONTAINER_PROJECT_NAME="cc-no-cache-$RANDOM-$$"
WORK_DIR=""

info() { printf '%s\n' "$*"; }
warning() { printf 'warning: %s\n' "$*" >&2; }
error() { printf 'error: %s\n' "$*" >&2; }

usage() {
    sed -n '/^# USAGE:/,/^# This parity/ { /^# This parity/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-build-no-cache-filter.sh/$SCRIPT_NAME/"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict) STRICT=1; shift ;;
            -h | --help) usage; exit 0 ;;
            *) error "unknown argument: $1"; usage >&2; return 2 ;;
        esac
    done
}

skip_or_fail() {
    local message="$1"
    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    warning "$message; skipping build no-cache-filter parity check"
    exit 0
}

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

check_tools() {
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is not available'
    command -v docker >/dev/null 2>&1 || skip_or_fail 'docker is not available'
    docker info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is not available'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    [[ -x "$CONTAINER_COMPOSE_NORMALIZER" ]] \
        || skip_or_fail "matching compose-normalizer is not executable: $CONTAINER_COMPOSE_NORMALIZER"
    [[ -f "$COMPOSE_FILE" ]] || {
        error "missing no-cache-filter fixture: $COMPOSE_FILE"
        return 1
    }
}

prepare_work_dir() {
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-compose-no-cache-filter.XXXXXX")"
}

cleanup() {
    if ((${#DOCKER_COMPOSE_COMMAND[@]} > 0)); then
        "${DOCKER_COMPOSE_COMMAND[@]}" \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$DOCKER_PROJECT_NAME" \
            --file "$COMPOSE_FILE" \
            down --rmi all --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        down --rmi all --volumes --remove-orphans >/dev/null 2>&1 || true
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

assert_filter_json() {
    local implementation="$1"
    local document_kind="$2"
    python3 -c '
import json
import sys

implementation, document_kind = sys.argv[1:3]
document = json.load(sys.stdin)
if document_kind == "config":
    build = document.get("services", {}).get("app", {}).get("build", {})
    key = "noCacheFilter" if implementation == "container-compose" else "no_cache_filter"
    actual = build.get(key)
else:
    build = document.get("target", {}).get("app", {})
    actual = build.get("no-cache-filter")
if actual != ["base", "compile"]:
    raise SystemExit(
        f"{implementation}: {document_kind} filter is {actual!r}, "
        "want [base, compile]"
    )
' "$implementation" "$document_kind"
}

check_config_and_bake() {
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json | assert_filter_json 'Docker Compose V2' config
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json | assert_filter_json container-compose config

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build --print app | assert_filter_json 'Docker Compose V2' bake
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build --print app | assert_filter_json container-compose bake
}

read_token() {
    local output_file="$1"
    awk '/^[0-9]+$/ { token = $0 } END { if (token == "") exit 1; print token }' "$output_file"
}

assert_rebuilt() {
    local implementation="$1"
    local first="$2"
    local second="$3"
    if [[ "$first" == "$second" ]]; then
        error "$implementation reused the filtered base stage: $first"
        return 1
    fi
}

check_docker_live() {
    local first_output="$WORK_DIR/docker-first.out"
    local second_output="$WORK_DIR/docker-second.out"
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build app >/dev/null
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        run --rm --no-deps app >"$first_output"
    sleep 2
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build app >/dev/null
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        run --rm --no-deps app >"$second_output"
    assert_rebuilt 'Docker Compose V2' "$(read_token "$first_output")" "$(read_token "$second_output")"
}

check_container_live() {
    if [[ "$CONTAINER_COMPOSE_LIVE" != "1" ]]; then
        info 'live Apple runtime validation not requested; Docker Compose V2 and model parity passed'
        return
    fi
    if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        error "matching Apple runtime binary is unavailable: $CONTAINER_BINARY"
        return 1
    fi
    "$CONTAINER_BINARY" system status >/dev/null

    local first_output="$WORK_DIR/container-first.out"
    local second_output="$WORK_DIR/container-second.out"
    env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build app >/dev/null
    env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        run --rm --no-deps app >"$first_output"
    sleep 2
    env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build app >/dev/null
    env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        run --rm --no-deps app >"$second_output"
    assert_rebuilt container-compose "$(read_token "$first_output")" "$(read_token "$second_output")"
}

main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    prepare_work_dir
    trap cleanup EXIT

    check_config_and_bake
    check_docker_live
    check_container_live

    info 'Docker Compose V2 and container-compose build no-cache-filter parity passed.'
}

main "$@"
