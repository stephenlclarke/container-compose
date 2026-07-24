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
#   check-compose-build-external-dockerfile.sh [options]
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
#   CONTAINER_COMPOSE_CONTAINER
#                           Runtime CLI used for matching live macOS validation.
#   CONTAINER_COMPOSE_LIVE  Set to 1 when an isolated matching Apple runtime is
#                           running.
#   DOCKER_COMPOSE          Docker Compose command to compare with.
#
# This parity check proves that a declared Dockerfile outside its local build
# context survives config and bake projection and builds through Docker Compose
# V2 and, when requested, the matching Apple runtime.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_DIR="$REPO_ROOT/Tools/parity/fixtures/build-external-dockerfile"
readonly COMPOSE_FILE="$FIXTURE_DIR/compose.yaml"
readonly EXPECTED_OUTPUT="external-dockerfile-parity-ok"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_COMPOSE_NORMALIZER="${CONTAINER_COMPOSE_NORMALIZER:-$REPO_ROOT/Tools/compose-normalizer/compose-normalizer}"
export CONTAINER_COMPOSE_NORMALIZER
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
DOCKER_COMPOSE_COMMAND=()
DOCKER_PROJECT_NAME="compose-ext-df-docker-$RANDOM-$$"
CONTAINER_PROJECT_NAME="cc-ext-df-$RANDOM-$$"

info() { printf '%s\n' "$*"; }
warning() { printf 'warning: %s\n' "$*" >&2; }
error() { printf 'error: %s\n' "$*" >&2; }

usage() {
    sed -n '/^# USAGE:/,/^# This parity/ { /^# This parity/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-build-external-dockerfile.sh/$SCRIPT_NAME/"
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
    warning "$message; skipping external Dockerfile parity check"
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
    [[ -x "$CONTAINER_COMPOSE" ]] \
        || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    [[ -x "$CONTAINER_COMPOSE_NORMALIZER" ]] \
        || skip_or_fail "matching compose-normalizer is not executable: $CONTAINER_COMPOSE_NORMALIZER"
    [[ -f "$COMPOSE_FILE" ]] || {
        error "missing external Dockerfile fixture: $COMPOSE_FILE"
        return 1
    }
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
}

assert_projected_paths() {
    local implementation="$1"
    local document_kind="$2"
    python3 -c '
import json
import pathlib
import sys

implementation, document_kind, fixture = sys.argv[1:4]
document = json.load(sys.stdin)
fixture_path = pathlib.Path(fixture).resolve()
want_context = (fixture_path / "context").as_posix()
want_dockerfile = (fixture_path / "Dockerfile").as_posix()
if document_kind == "config":
    build = document.get("services", {}).get("app", {}).get("build", {})
else:
    build = document.get("target", {}).get("app", {})
context_path = pathlib.Path(build.get("context", "")).resolve()
dockerfile_path = pathlib.Path(build.get("dockerfile", ""))
if not dockerfile_path.is_absolute():
    dockerfile_path = context_path / dockerfile_path
context = context_path.as_posix()
dockerfile = dockerfile_path.resolve().as_posix()
if context != want_context:
    raise SystemExit(f"{implementation}: {document_kind} context {context!r}, want {want_context!r}")
if dockerfile != want_dockerfile:
    raise SystemExit(f"{implementation}: {document_kind} Dockerfile {dockerfile!r}, want {want_dockerfile!r}")
' "$implementation" "$document_kind" "$FIXTURE_DIR"
}

check_projection() {
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json | assert_projected_paths 'Docker Compose V2' config
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json | assert_projected_paths container-compose config

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build --print app | assert_projected_paths 'Docker Compose V2' bake
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build --print app | assert_projected_paths container-compose bake
}

check_docker_live() {
    local output
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build app >/dev/null
    output="$("${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        run --rm --no-deps app)"
    [[ "$output" == *"$EXPECTED_OUTPUT"* ]] || {
        error "Docker Compose V2 external Dockerfile output was '$output'"
        return 1
    }
}

check_container_live() {
    local output
    if [[ "$CONTAINER_COMPOSE_LIVE" != "1" ]]; then
        info 'live Apple runtime validation not requested; Docker Compose V2 and model parity passed'
        return
    fi
    if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        error "matching Apple runtime binary is unavailable: $CONTAINER_BINARY"
        return 1
    fi
    "$CONTAINER_BINARY" system status >/dev/null
    env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build app >/dev/null
    output="$(env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        run --rm --no-deps app)"
    [[ "$output" == *"$EXPECTED_OUTPUT"* ]] || {
        error "container-compose external Dockerfile output was '$output'"
        return 1
    }
}

main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    trap cleanup EXIT
    check_projection
    check_docker_live
    check_container_live
    info 'Docker Compose V2 and container-compose external Dockerfile parity passed.'
}

main "$@"
