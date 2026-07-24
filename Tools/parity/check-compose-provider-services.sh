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
#   check-compose-provider-services.sh [options]
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
#                           running. The check then proves live provider parity.
#   DOCKER_COMPOSE          Docker Compose command to compare with. Defaults to
#                           "docker compose" when available, otherwise docker-compose.
#
# This local parity check proves provider setenv/rawsetenv injection, raw
# override diagnostics, and project-environment propagation against Docker
# Compose V2 and, when requested, the matching Apple runtime.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_DIR="$REPO_ROOT/Tools/parity/fixtures/provider-services"
readonly COMPOSE_FILE="$FIXTURE_DIR/compose.yaml"
readonly PROVIDER_EXECUTABLE="$FIXTURE_DIR/provider.sh"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
DOCKER_COMPOSE_COMMAND=()
DOCKER_PROJECT_NAME="container-compose-provider-docker-$RANDOM-$$"
CONTAINER_PROJECT_NAME="container-compose-provider-runtime-$RANDOM-$$"
WORK_DIR=""

info() { printf '%s\n' "$*"; }
warning() { printf 'warning: %s\n' "$*" >&2; }
error() { printf 'error: %s\n' "$*" >&2; }

usage() {
    sed -n '/^# USAGE:/,/^# This local parity/ { /^# This local parity/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-provider-services.sh/$SCRIPT_NAME/"
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
    warning "$message; skipping provider-services parity check"
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
    [[ -x "$PROVIDER_EXECUTABLE" ]] || {
        error "provider fixture is not executable: $PROVIDER_EXECUTABLE"
        return 1
    }
    [[ -f "$COMPOSE_FILE" ]] || {
        error "missing provider-services fixture: $COMPOSE_FILE"
        return 1
    }
}

prepare_work_dir() {
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-compose-provider-services.XXXXXX")"
}

with_provider_environment() {
    env -u PROVIDER_PROJECT_TOKEN PROVIDER_EXECUTABLE="$PROVIDER_EXECUTABLE" "$@"
}

cleanup() {
    if ((${#DOCKER_COMPOSE_COMMAND[@]} > 0)); then
        with_provider_environment "${DOCKER_COMPOSE_COMMAND[@]}" \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$DOCKER_PROJECT_NAME" \
            --file "$COMPOSE_FILE" \
            down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    with_provider_environment "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        down --volumes --remove-orphans >/dev/null 2>&1 || true
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

assert_config() {
    local implementation="$1"
    python3 -c '
import json
import sys

implementation = sys.argv[1]
project = json.load(sys.stdin)
app = project.get("services", {}).get("app", {})
provider = project.get("services", {}).get("secrets", {}).get("provider", {})
if app.get("environment", {}).get("CLOUD_REGION") != "user-defined-region":
    raise SystemExit(f"{implementation}: user environment was not retained")
if "secrets" not in app.get("depends_on", app.get("dependsOn", {})):
    raise SystemExit(f"{implementation}: provider dependency was not retained")
if provider.get("type") != sys.argv[2]:
    raise SystemExit(f"{implementation}: provider type was not retained: {provider!r}")
if provider.get("options", {}).get("name") not in ("secrets", ["secrets"]):
    raise SystemExit(f"{implementation}: provider options were not retained: {provider!r}")
' "$implementation" "$PROVIDER_EXECUTABLE"
}

check_config_parity() {
    with_provider_environment "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json | assert_config 'Docker Compose V2'
    with_provider_environment "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json | assert_config 'container-compose'
}

assert_provider_output() {
    local implementation="$1"
    local output_file="$2"
    local output
    output="$(cat "$output_file")"
    if [[ "$output" != *"SECRETS_URL=https://magic.cloud/secrets"* ]]; then
        error "$implementation did not inject the prefixed provider variable"
        sed -n '1,180p' "$output_file" >&2
        return 1
    fi
    if [[ "$output" != *"CLOUD_REGION=us-east-1"* ]] || \
        [[ "$output" == *"CLOUD_REGION=user-defined-region"* ]]; then
        error "$implementation did not override the raw provider variable"
        sed -n '1,180p' "$output_file" >&2
        return 1
    fi
    if [[ "$output" != *"overrides environment variable"* ]]; then
        error "$implementation did not surface the raw provider override"
        sed -n '1,180p' "$output_file" >&2
        return 1
    fi
}

check_docker_compose() {
    local output_file="$WORK_DIR/docker-compose-up.log"
    with_provider_environment "${DOCKER_COMPOSE_COMMAND[@]}" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        up --abort-on-container-exit --exit-code-from app app >"$output_file" 2>&1
    assert_provider_output 'Docker Compose V2' "$output_file"
}

check_container_compose() {
    if [[ "$CONTAINER_COMPOSE_LIVE" != "1" ]]; then
        info 'live Apple runtime validation not requested; Docker Compose V2 and model parity passed'
        return
    fi
    if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        error "matching Apple runtime binary is unavailable: $CONTAINER_BINARY"
        return 1
    fi
    "$CONTAINER_BINARY" system status >/dev/null

    local output_file="$WORK_DIR/container-compose-up.log"
    with_provider_environment env \
        CONTAINER_BIN="$CONTAINER_BINARY" \
        CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        up --abort-on-container-exit --exit-code-from app app >"$output_file" 2>&1
    assert_provider_output 'container-compose' "$output_file"
}

main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    prepare_work_dir
    trap cleanup EXIT

    check_config_parity
    check_docker_compose
    check_container_compose

    info 'Docker Compose V2 and container-compose provider-services parity passed.'
}

main "$@"
